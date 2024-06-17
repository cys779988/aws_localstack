#!/bin/bash

# SQS URL에서 큐 이름 추출
extract_queue_name() {
  local sqs_url=$1
  local queue_name=$(echo $sqs_url | awk -F'/' '{print $NF}' | sed 's/dev-queue-//')
  echo $queue_name
}

# LocalStack 엔드포인트
LOCALSTACK_ENDPOINT="http://localhost:4566"

# Docker Compose를 통해 전달된 환경 변수 사용
AWS_ACCESS_KEY_ID=${X_AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${X_AWS_SECRET_ACCESS_KEY}
AWS_REGION=${X_AWS_REGION}

# 실제 AWS CLI를 사용하여 SQS 및 SNS 자원 가져오기
aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
aws configure set region $AWS_REGION

apt-get update && apt-get install -y jq

# "dev-queue"가 포함된 SQS 큐 목록 가져오기
queues=$(aws sqs list-queues --region $AWS_REGION --output json | jq -r '.QueueUrls[] | select(contains("dev-queue"))')
# "dev-"가 포함된 SNS 주제 목록 가져오기
topics=$(aws sns list-topics --region $AWS_REGION --output json | jq -r '.Topics[].TopicArn | select(contains("dev-"))')

# 로컬 환경에서 SQS 큐 및 SNS 주제 생성
for queue_url in $queues; do
  queue_name=$(extract_queue_name "$queue_url")
  echo "Creating SQS queue $queue_name"
  
  # 큐 생성
  aws --endpoint-url=$LOCALSTACK_ENDPOINT sqs create-queue --queue-name "dev-queue-$queue_name"
  
  # 큐 속성 가져오기
  queue_attributes=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-name All --output json)
  
  # 큐 속성 설정
  for attribute in $(echo $queue_attributes | jq -r 'keys[]'); do
    value=$(echo $queue_attributes | jq -r --arg attr "$attribute" '.[$attr]')
    aws --endpoint-url=$LOCALSTACK_ENDPOINT sqs set-queue-attributes --queue-url "$queue_url" --attributes "$attribute=$value"
  done
done

for topic_arn in $topics; do
  topic_name=$(echo $topic_arn | awk -F':' '{print $NF}')
  echo "Creating SNS topic $topic_name"
  aws --endpoint-url=$LOCALSTACK_ENDPOINT sns create-topic --name "$topic_name"
done

local_queues=$(awslocal sqs list-queues | jq -r '.QueueUrls[]')
local_topics=$(awslocal sns list-topics | jq -r '.Topics[].TopicArn')

# SQS 큐를 SNS 주제에 구독 설정
for queue_url in $local_queues; do
  queue_name=$(extract_queue_name "$queue_url")
  queue_arn=$(aws --endpoint-url=$LOCALSTACK_ENDPOINT sqs get-queue-attributes --queue-url "$queue_url" --attribute-name QueueArn | jq -r '.Attributes.QueueArn')
  echo "Queue ARN for $queue_name: $queue_arn"
  for topic_arn in $local_topics; do
    echo "Checking if $topic_arn contains $queue_name"
    if echo "$topic_arn" | grep -q "$queue_name"; then
      echo "Subscribing $queue_arn to $topic_arn"
      aws --endpoint-url=$LOCALSTACK_ENDPOINT sns subscribe --topic-arn "$topic_arn" --protocol sqs --notification-endpoint "$queue_arn"
      break
    fi
  done
done

echo "------------------------------Initialization complete.------------------------------"
