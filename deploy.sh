#!/bin/bash
set -eo pipefail

# Check if madlibs.sh exists
if [[ ! -f "madlibs.sh" ]]; then
    echo "Can't find madlibs.sh. Please ensure the file is in the current directory."
    exit 1
fi

# Check if AWS credentials are set
if [[ -z "${AWS_ACCESS_KEY_ID}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
    echo "AWS credentials are not set. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables. Do this by running \`AWS_ACCESS_KEY_ID=yourkey AWS_SECRET_ACCESS_KEY=yoursecretkey deploy.sh\`"
    exit 1
fi

set -u

# Set AWS credentials
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-<your-secret-access-key>}
export AWS_PAGER=""
export AWS_DEFAULT_REGION=eu-west-1
aws_region=eu-west-1
acc_id=488559761265

# Create or read the hidden file for the random string
if [[ ! -f ".lambda_id" ]]; then
    echo "Creating hidden file with random ID for Lambda function"
    echo $(head -c 1000 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 10) > .lambda_id
fi
lambda_id=$(cat .lambda_id)

# Set the function name with the current date and the lambda_id
current_date=$(date +%Y-%m-%d)
function_name="madlibs-${current_date}-${lambda_id}"

echo "Deploying function: $function_name"

# Create bootstrap file
cat <<'EOF' > bootstrap
#!/bin/sh
set -euo pipefail

# Load the bash script
##source $(dirname "$0")/script.sh

# Process events in a loop
while true
do
    # Get the next invocation event
    HEADERS="$(mktemp)"
    EVENT_DATA=$(curl -sS -LD "$HEADERS" -X GET "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/next")
    REQUEST_ID=$(grep -Fi Lambda-Runtime-Aws-Request-Id "$HEADERS" | tr -d '[:space:]' | cut -d: -f2)

    # Execute the bash script and capture the output
    OUTPUT=$(bash madlibs.sh)

    # Send the response back to the Lambda runtime API
    RESPONSE="{\"statusCode\": 200, \"body\": \"$OUTPUT\"}"
    curl -X POST "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/$REQUEST_ID/response" -d "$RESPONSE"
done
EOF

chmod +x bootstrap madlibs.sh

# Create a zip file containing the Lambda function code
zip -r lambda_function.zip madlibs.sh bootstrap

# Check if the Lambda function already exists
function_exists=$(aws lambda get-function --function-name $function_name 2>&1 || true)
if [[ $function_exists == *"ResourceNotFoundException"* ]]; then
    # Create the Lambda function if it doesn't exist
    aws lambda create-function --function-name $function_name \
      --runtime provided.al2 --handler madlibs.handler \
      --zip-file fileb://lambda_function.zip --role arn:aws:iam::$acc_id:role/DO4-U1W-lambda-execution
else
    # Update the Lambda function if it already exists
    aws lambda update-function-code --function-name $function_name \
      --zip-file fileb://lambda_function.zip
fi

rm lambda_function.zip bootstrap

# Check if the API Gateway REST API already exists
api_id=$(aws apigateway get-rest-apis --query "items[?name=='U1W Madlibs ${current_date}-${lambda_id}'].id" --output text)

if [[ -z "$api_id" ]]; then
    # Create the API Gateway REST API if it doesn't exist
    api_id=$(aws apigateway create-rest-api --name "U1W Madlibs ${current_date}-${lambda_id}" --query 'id' --output text)
    
    # Get the root resource ID
    root_resource_id=$(aws apigateway get-resources --rest-api-id $api_id --query 'items[0].id' --output text)
    
    # Create the /madlibs resource
    resource_id=$(aws apigateway create-resource --rest-api-id $api_id --parent-id $root_resource_id --path-part madlibs --query 'id' --output text)
    
    # Create the GET method for the /madlibs resource
    aws apigateway put-method --rest-api-id $api_id --resource-id $resource_id --http-method GET --authorization-type NONE
    
    # Integrate the GET method with the Lambda function
    aws apigateway put-integration --rest-api-id $api_id --resource-id $resource_id --http-method GET --type AWS_PROXY --integration-http-method POST --uri arn:aws:apigateway:$aws_region:lambda:path/2015-03-31/functions/arn:aws:lambda:$aws_region:$acc_id:function:$function_name/invocations
    
    # Deploy the API Gateway
    aws apigateway create-deployment --rest-api-id $api_id --stage-name prod
    
    # Grant API Gateway permission to invoke the Lambda function
    aws lambda add-permission --function-name "$function_name" --statement-id apigateway-invoke --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn arn:aws:execute-api:$aws_region:$acc_id:$api_id/*/GET/madlibs
else
    
    # Attach the jq layer to our function so that it's available as a tool
    # This only runs after the first run, so that the Lambda is online already
    aws lambda update-function-configuration --function-name $function_name --layers arn:aws:lambda:eu-west-1:488559761265:layer:jq:2 --region $aws_region

    # Get the /madlibs resource ID
    resource_id=$(aws apigateway get-resources --rest-api-id $api_id --query "items[?path=='/madlibs'].id" --output text)
    
    # Update the GET method integration with the Lambda function
    aws apigateway put-integration --rest-api-id $api_id --resource-id $resource_id --http-method GET --type AWS_PROXY --integration-http-method POST --uri arn:aws:apigateway:$aws_region:lambda:path/2015-03-31/functions/arn:aws:lambda:$aws_region:$acc_id:function:$function_name/invocations
    
    # Redeploy the API Gateway
    aws apigateway create-deployment --rest-api-id $api_id --stage-name prod
fi

echo "Deployment complete. Access your new Mad Libs site at: https://$api_id.execute-api.$aws_region.amazonaws.com/prod/madlibs"
