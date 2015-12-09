#!/usr/bin/env ruby
VERSION = "0.0.1"
require 'slop'
require 'pathname'
require 'fileutils'
require 'aws-sdk'
require 'csv'
require "base64"


opts = Slop.parse do |o|
  o.string '-t', '--table', 'DynamoDB Table to restore, defaults to ${TABLE_NAME}', default: ENV['TABLE_NAME']
  o.string '-b', '--bucket', 'Bucket containing backup files, defaults to  ${BACKUP_FILE_BUCKET}', default: ENV['BACKUP_FILE_BUCKET']
  o.string '-f', '--file', 'The file to restore, including any s3 folder paths, defaults to ${FILE}', default: ENV['FILE']
  o.string '-k', '--kinesis-stream', 'Kinesis Stream to process put requests, see lambda-dynamodb-put, defaults to ${KINESIS_STREAM}', default: ENV['KINESIS_STREAM']
  o.integer '-p','--partitions', 'The number of partitions to use when sending to the Kinesis Stream, defaults to 500', default: 500
  o.integer '-c','--chunk-size', 'Split the backup file into chunks of this number of lines, defaults to 500,000', default: 500000
  o.string '-r', '--region', 'Region for AWS API calls, defaults to ${AWS_REGION}', default: ENV['AWS_REGION']
  o.string '-d', '--task', 'Task Definition to execute the restore, defaults to ${TASK_DEFINITION}', default: ENV['TASK_DEFINITION']
  o.string '-l', '--cluster', 'The ECS Cluster to run the restore tasks ${CLUSTER}', default: ENV['CLUSTER']
  o.string '-s', '--service-name', 'The name of the service ${SERVICE_NAME}', default: ENV['SERVICE_NAME']
  o.boolean '--help', 'Display Help'
  o.on '--version', 'print the version' do
    puts VERSION
    exit
  end
end

if opts[:help]
  puts opts
  exit
end

# The local folder to downlod S3 file to
folder = Pathname.new("/stockflare/data/dynamodb_backup_#{Time.now.strftime('%FT%T%:z')}")
# The full path of the local CSV file
full_file_name = folder + Pathname.new(opts[:file]).basename

# search path for chunk files
chunk_prefix = (Pathname.new(opts[:file]).basename).to_s.split('.')[0] + '_CHUNK'
chunk_name = folder + chunk_prefix
chunk_files = chunk_name.to_s + '*'
puts chunk_files

s3 = Aws::S3::Client.new

# Create the folder for the backup file if needed
FileUtils::mkdir_p folder if !File.exists? folder

# Delete the file if it exists
File.delete(full_file_name) if File.exists?(full_file_name)

# Delete the Chunk files if needed
Dir[chunk_files].each do |chunk_file|
  File.delete(folder + chunk_file) if File.exists?(folder + chunk_file)
end

# Copy the file from S3
File.open(full_file_name, 'wb') do |file|
  s3.get_object(bucket: opts[:bucket], key: opts[:file]) do |chunk|
    file.write(chunk)
  end
end

# Split the input file into chunks
cmd = "cd #{folder}; split --lines=#{opts['chunk-size']} --verbose --numeric-suffixes=0 #{full_file_name} #{chunk_prefix}"
puts cmd
`#{cmd}`

# For each chunk file, upload to S3 and then kick off restore process
Dir[chunk_files].each do |chunk_file|
  s3_chunk_file = Pathname.new(opts[:file]).dirname + Pathname.new(chunk_file).basename
  puts s3_chunk_file
  s3 = Aws::S3::Resource.new(region: opts[:region])
  obj = s3.bucket(opts[:bucket]).object(s3_chunk_file.to_s)
  obj.upload_file(folder + chunk_file)

  # Kick off the task to restore this chunk file

  ecs = Aws::ECS::Client.new(
    region: opts[:region]
  )

  resp = ecs.run_task({
    cluster: opts[:cluster],
    task_definition: opts[:task],
    overrides: {
      container_overrides: [
        {
          name: opts['service-name'],
          environment: [
            {
              name: "TABLE_NAME",
              value: opts[:table],
            },
            {
              name: "BACKUP_FILE_BUCKET",
              value: opts[:bucket]
            },
            {
              name: "FILE",
              value: s3_chunk_file.to_s
            },
            {
              name: "KINESIS_STREAM",
              value: opts['kinesis-stream']
            },
            {
              name: "AWS_REGION",
              value: opts['region']
            }
          ]
        }
      ]
    },
    count: 1,
    started_by: "dynamodb-setup-restore"
  })

  puts resp.inspect

end
