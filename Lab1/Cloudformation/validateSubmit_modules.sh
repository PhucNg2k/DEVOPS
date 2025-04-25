#!/bin/bash

# Configuration
MODULES_DIR="modules"
REGION="us-east-1"
LOG_FILE="process_log.txt"
ROLE_ARN="arn:aws:iam::175439332815:role/LabRole"

# Clear the log file
> "$LOG_FILE"

# Function to log messages
log() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Check dependencies
if ! command -v aws &> /dev/null; then
    log "❌ AWS CLI is not installed. Please install it first."
    exit 1
fi

if ! command -v cfn &> /dev/null; then
    log "❌ CloudFormation CLI is not installed. Please install it first."
    exit 1
fi

# Verify AWS credentials
log "Verifying AWS credentials..."
aws sts get-caller-identity >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "❌ AWS credentials are not configured correctly."
    exit 1
fi

# Assume LabRole
log "Assuming LabRole: $ROLE_ARN..."
ROLE_CREDENTIALS=$(aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name ModuleProcessSession \
    --region "$REGION" 2>> "$LOG_FILE")
if [ $? -ne 0 ]; then
    log "❌ Failed to assume LabRole. Check permissions and trust policy."
    exit 1
fi

export AWS_ACCESS_KEY_ID=$(echo "$ROLE_CREDENTIALS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ROLE_CREDENTIALS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ROLE_CREDENTIALS" | jq -r '.Credentials.SessionToken')
log "✅ Successfully assumed LabRole."

# Iterate through each module directory
for module_dir in "$MODULES_DIR"/*/ ; do
    if [ -d "$module_dir" ]; then
        module_name=$(basename "$module_dir")
        log "🔧 Processing module: $module_name"

        # Check for .rpdk-config
        rpdk_config="${module_dir}.rpdk-config"
        if [ ! -f "$rpdk_config" ]; then
            log "❌ Error: .rpdk-config not found in $module_dir"
            continue
        fi
        log "✅ Found $rpdk_config"

        # Read typeName from .rpdk-config
        type_name=$(jq -r '.typeName' "$rpdk_config")
        if [ -z "$type_name" ]; then
            log "❌ Error: typeName not found in $rpdk_config"
            continue
        fi
        log "✅ Extracted typeName: $type_name"

        # Validate module schema
        log "🔍 Validating module $module_name..."
        (cd "$module_dir" && cfn validate) >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log "❌ Error: Validation failed for $module_name. Check $LOG_FILE for details."
            continue
        fi
        log "✅ Module $module_name schema is valid."

        # Submit module
        log "📬 Submitting module $module_name..."
        (cd "$module_dir" && cfn submit --region "$REGION" --role-arn "$ROLE_ARN") >> "$LOG_FILE" 2>&1
        if [ $? -ne 0 ]; then
            log "❌ Error: Failed to submit module $module_name. Check $LOG_FILE and rpdk.log for details."
            continue
        fi
        log "✅ Successfully submitted module $module_name."

        # Verify registration
        log "🔍 Verifying registration for $module_name..."
        sleep 5  # Wait for registration to process
        aws cloudformation describe-type \
            --type MODULE \
            --type-name "$type_name" \
            --region "$REGION" >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log "🎉 Successfully registered module $module_name"
        else
            log "⚠️ Warning: Verification failed for $module_name. Check AWS Console."
        fi
    fi
done

log "✅ Module processing completed."