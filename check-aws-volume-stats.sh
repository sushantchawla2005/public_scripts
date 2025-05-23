#!/bin/bash

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <EC2-IP> <AWS-REGION> <AWS-PROFILE>"
  exit 1
fi

EC2_IP="$1"
REGION="$2"
PROFILE="$3"

echo "🔍 Looking up EC2 instance with IP: $EC2_IP"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=ip-address,Values=$EC2_IP" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Reservations[].Instances[].InstanceId" --output text)

if [ -z "$INSTANCE_ID" ]; then
  echo "❌ No instance found with IP $EC2_IP"
  exit 2
fi

echo "✅ Instance ID: $INSTANCE_ID"
echo "📦 Fetching attached volume IDs..."

VOLUME_IDS=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId" \
  --output text)

START=$(date -u -v-7d '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

for VOL_ID in $VOLUME_IDS; do
  VOLUME_DETAILS=$(aws ec2 describe-volumes \
    --volume-ids "$VOL_ID" \
    --region "$REGION" --profile "$PROFILE" \
    --query "Volumes[0].[VolumeType,Size,Iops,Throughput]" --output text)

  VOLUME_TYPE=$(echo "$VOLUME_DETAILS" | awk '{print $1}')
  VOLUME_SIZE=$(echo "$VOLUME_DETAILS" | awk '{print $2}')
  VOLUME_IOPS=$(echo "$VOLUME_DETAILS" | awk '{print $3}')
  VOLUME_TP=$(echo "$VOLUME_DETAILS" | awk '{print $4}')

  echo ""
  echo "📊 Top 5 Throughput (MiB/s) for Volume: $VOL_ID ($VOLUME_TYPE, ${VOLUME_SIZE}GiB, IOPS: $VOLUME_IOPS, TP: ${VOLUME_TP:-N/A}MiB/s)"

  aws cloudwatch get-metric-data \
    --metric-data-queries "[
      {
        \"Id\": \"rb\",
        \"MetricStat\": {
          \"Metric\": {
            \"Namespace\": \"AWS/EBS\",
            \"MetricName\": \"VolumeReadBytes\",
            \"Dimensions\": [{\"Name\": \"VolumeId\", \"Value\": \"$VOL_ID\"}]
          },
          \"Period\": 60,
          \"Stat\": \"Sum\"
        },
        \"ReturnData\": false
      },
      {
        \"Id\": \"wb\",
        \"MetricStat\": {
          \"Metric\": {
            \"Namespace\": \"AWS/EBS\",
            \"MetricName\": \"VolumeWriteBytes\",
            \"Dimensions\": [{\"Name\": \"VolumeId\", \"Value\": \"$VOL_ID\"}]
          },
          \"Period\": 60,
          \"Stat\": \"Sum\"
        },
        \"ReturnData\": false
      },
      {
        \"Id\": \"tp\",
        \"Expression\": \"(rb+wb)/60/1024/1024\",
        \"Label\": \"Throughput (MiB/s)\",
        \"ReturnData\": true
      }
    ]" \
    --start-time "$START" \
    --end-time "$END" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --output json > /tmp/cloudwatch_throughput_$VOL_ID.json

  jq -r '
    .MetricDataResults[]
    | select(.Id == "tp")
    | [ .Timestamps, .Values ]
    | transpose
    | map({time: .[0], value: .[1]})
    | sort_by(.value) | reverse
    | .[:5][]
    | [.time, (.value | tostring)] | @tsv
  ' /tmp/cloudwatch_throughput_$VOL_ID.json

  echo ""
  echo "📈 Top 5 IOPS for Volume: $VOL_ID ($VOLUME_TYPE, ${VOLUME_SIZE}GiB, IOPS: $VOLUME_IOPS, TP: ${VOLUME_TP:-N/A}MiB/s)"

  aws cloudwatch get-metric-data \
    --metric-data-queries "[
      {
        \"Id\": \"ro\",
        \"MetricStat\": {
          \"Metric\": {
            \"Namespace\": \"AWS/EBS\",
            \"MetricName\": \"VolumeReadOps\",
            \"Dimensions\": [{\"Name\": \"VolumeId\", \"Value\": \"$VOL_ID\"}]
          },
          \"Period\": 60,
          \"Stat\": \"Sum\"
        },
        \"ReturnData\": false
      },
      {
        \"Id\": \"wo\",
        \"MetricStat\": {
          \"Metric\": {
            \"Namespace\": \"AWS/EBS\",
            \"MetricName\": \"VolumeWriteOps\",
            \"Dimensions\": [{\"Name\": \"VolumeId\", \"Value\": \"$VOL_ID\"}]
          },
          \"Period\": 60,
          \"Stat\": \"Sum\"
        },
        \"ReturnData\": false
      },
      {
        \"Id\": \"iops\",
        \"Expression\": \"(ro+wo)/60\",
        \"Label\": \"IOPS\",
        \"ReturnData\": true
      }
    ]" \
    --start-time "$START" \
    --end-time "$END" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --output json > /tmp/cloudwatch_iops_$VOL_ID.json

  jq -r '
    .MetricDataResults[]
    | select(.Id == "iops")
    | [ .Timestamps, .Values ]
    | transpose
    | map({time: .[0], value: .[1]})
    | sort_by(.value) | reverse
    | .[:5][]
    | [.time, (.value | tostring)] | @tsv
  ' /tmp/cloudwatch_iops_$VOL_ID.json

done
