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
  o.string '-d', '--decode', 'Decode the row data from Base64, defaults to true', default: true
  o.string '-k', '--kinesis-stream', 'Kinesis Stream to process put requests, see lambda-dynamodb-put, defaults to ${KINESIS_STREAM}', default: ENV['KINESIS_STREAM']
  o.integer '-p','--partitions', 'The number of partitions / shards to use when sending to the Kinesis Stream, defaults to 10', default: 10
  o.string '-r', '--region', 'Region for AWS API calls, defaults to ${AWS_REGION}', default: ENV['AWS_REGION']
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
folder = Pathname.new('/stockflare/data/dynamodb_backup')
# The full path of the local CSV file
full_file_name = folder + Pathname.new(opts[:file]).basename

s3 = Aws::S3::Client.new

kinesis = Aws::Kinesis::Client.new(region: opts[:region])

# Create the folder for the backup file if needed
FileUtils::mkdir_p folder if !File.exists? folder

# Delete the file if it exists
File.delete(full_file_name) if File.exists?(full_file_name)

# Copy the file from S3
File.open(full_file_name, 'wb') do |file|
  s3.get_object(bucket: opts[:bucket], key: opts[:file]) do |chunk|
    file.write(chunk)
  end
end

# Read CSV file and send to Kinesis
request = 0
records = []

CSV.foreach(full_file_name, converters: nil, encoding: "UTF-8", headers: false) do |row|
  # Extract the row data
  if opts[:decode]
    text = Base64.decode64(row[0])
    item = JSON.parse(text)
  else
    item = JSON.parse(row[0])
  end

  # Set up the Kinesis Payload
  request = request + 1
  shard = request % opts[:partitions]

  payload = {
    TableName: opts[:table],
    Item: item
  }

  puts payload

  # Set up the record to send in a bulk request
  record = {
    data: JSON.dump(payload),
    partition_key: "PartitionKey-#{shard}"
  }

  # Add this record to the bulk request
  records << record

  # Send the bulk request if you have reached either 500 records ot 4.75MB
  if records.count >= 500 || JSON.dump(records).bytesize > 4750000
    begin
      resp = kinesis.put_records({
        stream_name: opts['kinesis-stream'],
        records: records
      })
      puts resp.inspect
      # Reset the bulk request
      records = []
    rescue Aws::Kinesis::Errors::ServiceError => e
      puts e.inspect
      exit
    end
  end
  puts "Sent record: #{request}"
end
