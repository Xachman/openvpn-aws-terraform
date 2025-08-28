import json
import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm_client = boto3.client('ssm')

def lambda_handler(event, context):
    """
    Lambda function triggered by EventBridge when SSM documents change.
    Automatically executes the updated document on the OpenVPN instance.
    """
    
    try:
        logger.info(f"Received event: {json.dumps(event)}")
        
        # Extract document information from EventBridge event
        detail = event.get('detail', {})
        document_name = detail.get('document-name')
        document_version = detail.get('document-version', '$LATEST')
        
        if not document_name:
            logger.error("No document name found in event")
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'No document name provided'})
            }
        
        # Only process OpenVPN-related documents
        if not document_name.startswith('OpenVPN-'):
            logger.info(f"Ignoring non-OpenVPN document: {document_name}")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'Document ignored - not OpenVPN related'})
            }
        
        # Get the OpenVPN instance ID from environment variable
        instance_id = os.environ.get('OPENVPN_INSTANCE_ID')
        if not instance_id:
            logger.error("OPENVPN_INSTANCE_ID environment variable not set")
            return {
                'statusCode': 500,
                'body': json.dumps({'error': 'Instance ID not configured'})
            }
        
        logger.info(f"Executing document {document_name} on instance {instance_id}")
        
        # Check if instance is available for SSM
        try:
            response = ssm_client.describe_instance_information(
                InstanceInformationFilterList=[
                    {
                        'key': 'InstanceIds',
                        'valueSet': [instance_id]
                    }
                ]
            )
            
            if not response['InstanceInformationList']:
                logger.error(f"Instance {instance_id} not found or not SSM-enabled")
                return {
                    'statusCode': 400,
                    'body': json.dumps({'error': 'Instance not available for SSM'})
                }
                
        except Exception as e:
            logger.error(f"Error checking instance availability: {str(e)}")
            return {
                'statusCode': 500,
                'body': json.dumps({'error': f'Error checking instance: {str(e)}'})
            }
        
        # Get document parameters to provide defaults if needed
        try:
            doc_info = ssm_client.describe_document(Name=document_name)
            parameters = doc_info.get('Document', {}).get('Parameters', [])
            
            # Build parameters with defaults for the document
            document_parameters = {}
            for param in parameters:
                param_name = param.get('Name', '')
                param_default = param.get('DefaultValue', '')
                if param_default:
                    document_parameters[param_name] = param_default
                    
        except Exception as e:
            logger.warning(f"Could not get document parameters: {str(e)}")
            document_parameters = {}
        
        # Execute the SSM document
        try:
            response = ssm_client.send_command(
                InstanceIds=[instance_id],
                DocumentName=document_name,
                DocumentVersion=document_version,
                Parameters=document_parameters,
                TimeoutSeconds=300,
                Comment=f"Auto-executed due to document update via EventBridge"
            )
            
            command_id = response['Command']['CommandId']
            
            logger.info(f"Command {command_id} sent successfully to instance {instance_id}")
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'message': 'SSM command sent successfully',
                    'command_id': command_id,
                    'instance_id': instance_id,
                    'document_name': document_name,
                    'document_version': document_version
                })
            }
            
        except Exception as e:
            logger.error(f"Error sending SSM command: {str(e)}")
            return {
                'statusCode': 500,
                'body': json.dumps({'error': f'Error executing command: {str(e)}'})
            }
        
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': f'Unexpected error: {str(e)}'})
        }