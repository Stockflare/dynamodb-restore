# DynamoDB Restore

A Ruby command line script to restore DynamoDB data that has been previously backup up by https://github.com/Stockflare/dynamodb-backup.

Although the Backup script is a Node.JS JavaScript project, the AWS JavaScript API is unsuitable for the restore script due to its async nature.  Ruby was chosen as Ruby and the AWS API can ensure that each record is read and restored synchronously.

## Data restoration strategy
Data restoration is a two step process:
* This script will download the S3 CSV backup file
* Each record will be read
* The record will be Base64 decoded if the --decode option has been used
* the record will be JSON.parsed
* At this stage you should have a reconstituted DynamoDB Item like the one below
 ```
{"updated_at"=>{"N"=>"1447203612"}, "id"=>{"S"=>"bnpkOnVzZA==\n"}, "rate"=>{"N"=>"0.6550358501120767"}}
```

* A payload is created which represents a JavaScript AWS API DynamoDB putRecord payload such as
```
{
  TableName: <table_name>,
  Item: {"updated_at"=>{"N"=>"1447203612"}, "id"=>{"S"=>"bnpkOnVzZA==\n"}, "rate"=>{"N"=>"0.6550358501120767"}}
}
```
* The payload is then sent to a Kinesis Stream provided by https://github.com/Stockflare/lambda-dynamodb-put . This Lambda function is responsible for reading all payloads from the Kinesis stream and executing the DynamoDB put.

The Kinesis / Lambda function approach allows the actual restoration of the data to be scaled effectively, we simply need to increase the number of shard on the Kinesis stream to scale up the data restoration throughput.  Additionally the Lambda system will re-try record puts that fail for capacity or other reasons.

Records are sent to Kinesis in batches of 500 records or 4.75MB of data.

## Usage
```
usage: ./dynamodb-restore.rb [options]
    -t, --table           DynamoDB Table to restore
    -b, --bucket          Bucket containing backup files, defaults to  ${BACKUP_FILE_BUCKET}
    -f, --file            The file to restore, including any s3 folder paths
    -d, --decode          Decode the row data from Base64
    -k, --kinesis-stream  Kinesis Stream to process put requests, see lambda-dynamodb-put, defaults to ${KINESIS_STREAM}
    -p, --partitions      The number of partitions / shards to use when sending to the Kinesis Stream, defaults to 10
    -r, --region          Region for AWS API calls, defaults to ${AWS_REGION}
    --help                Display Help
    --version             print the version
```

## Cloudformation
The provided Cloudformation will deploy a ECS Container Service Task Definition that can be launched to execute restores.  This Cloudformation requires that the stacks for https://github.com/Stockflare/lambda-dynamodb-put and https://github.com/Stockflare/dynamodb-backup are already launched.
