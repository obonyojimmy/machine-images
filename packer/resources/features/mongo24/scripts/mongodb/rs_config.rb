## Service Discovery
#
# We need a means of finding the replica set primary host so that an 'auto-scaled' host
# can add itself into the replica set at EC2 instance launch/bootstrap time.
# This should probably use a more comprehensive service discovery mechanism but for now we simply
# maintain a list of replica set hosts in S3.
#
require 'aws-sdk'
require 'securerandom'
require_relative '../aws/helpers'
require_relative '../util/logger'

module MongoDB
  class ReplicaSetConfig
    include Util::LoggerMixin

    attr_reader :key

    def build_replica_set_key
      tags = AwsHelper::InstanceData::get_tags
      [tags['Stack'], tags['App'], tags['Stage']].join('-')
    end

    def initialize(key=nil)
      @key = key || build_replica_set_key
      @table_name = "mongo.rsconfig.#{@key}"
      ensure_table_exists
    end

    def name
      @name ||= fetch_replica_data['ReplicaSetName']
    end

    def seeds
      fetch_replica_data['SeedList']
    end

    def security_data
      rs_data = fetch_replica_data
      { :key => rs_data['Key'],
        :admin_user => rs_data['AdminUser'],
        :admin_password => rs_data['AdminPassword'] }
    end

    def add_seed(obj)
      current = seeds
      if current.include?(obj)
        current
      else
        update_seed_list(current, current + [obj])
        seeds
      end
    end

    def remove_seed(obj)
      current = seeds
      if current.include?(obj)
        update_seed_list(current, current - [obj])
        seeds
      else
        current
      end
    end

    def update_seed_list(old_list, new_list)
      dynamo.update_item(
        :table_name => @table_name,
        :key => { :ReplicaSetKey => @key },
        :update_expression => 'SET SeedList = :new_list',
        :condition_expression => 'SeedList = :old_list',
        :expression_attribute_values => { ':old_list' => old_list, ':new_list' => new_list }
      )
    end

    def fetch_replica_data
      replica_set_record = dynamo.get_item(
        :table_name => @table_name,
        :key => { :ReplicaSetKey => @key },
        :consistent_read => true
      ).data.item

      if !replica_set_record.nil?
        # return the seed list
        replica_set_record
      else
        begin
          # this is a new replica set config, so
          admin_password = secure_random_64(16)
          key = secure_random_64(700)
          dynamo.put_item(
            :table_name => @table_name,
            :item => {
              :ReplicaSetKey => @key,
              :ReplicaSetName => @key,
              :SeedList => [],
              :AdminUser => 'aws-admin',
              :AdminPassword => admin_password,
              :Key => key
            },
            :expected => { :SeedListName => { :comparison_operator => 'NULL'} }
          )
          logger.info 'added default record'
        rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
          logger.info 'record exists'
        end
        fetch_replica_data
      end
    end

    def ensure_table_exists
      ## Create the table if it doesn't exist
      begin
        dynamo.describe_table(:table_name => @table_name)
      rescue Aws::DynamoDB::Errors::ResourceNotFoundException
        dynamo.create_table(
          :table_name => @table_name,
          :attribute_definitions => [
            {
              :attribute_name => :ReplicaSetKey,
              :attribute_type => :S
            }
          ],
          :key_schema => [
            {
              :attribute_name => :ReplicaSetKey,
              :key_type => :HASH
            }
          ],
          :provisioned_throughput => {
            :read_capacity_units => 1,
            :write_capacity_units => 1,
          }
        )

        # wait for table to be created
        dynamo.wait_until(:table_exists, :table_name => @table_name)
      end
    end

    def dynamo
      @db ||= Aws::DynamoDB::Client.new
    end

    def secure_random_64(length)
      # This ensures that the value returned never has any '=' symbols
      # (valid base64, but not valid in a keyFile)
      SecureRandom.base64(length+3)[0..length-1]
    end

  end
end
