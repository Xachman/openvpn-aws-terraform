provider "aws" {
  region = var.region
}

# Fetch latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

resource "aws_security_group" "openvpn_sg" {
  name        = "openvpn-sg"
  description = "Allow OpenVPN and SSH traffic"
  vpc_id      = data.aws_subnet.selected.vpc_id

  ingress {
    description = "OpenVPN TCP"
    from_port   = 1194
    to_port     = 1194
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "OpenVPN UDP"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM role for EC2 instance to use SSM
resource "aws_iam_role" "openvpn_instance_role" {
  name = "openvpn-instance-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the SSM managed policy to the instance role
resource "aws_iam_role_policy_attachment" "openvpn_ssm_policy" {
  role       = aws_iam_role.openvpn_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create instance profile for the role
resource "aws_iam_instance_profile" "openvpn_profile" {
  name = "openvpn-instance-profile"
  role = aws_iam_role.openvpn_instance_role.name
}

resource "aws_instance" "openvpn_server" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.openvpn_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.openvpn_profile.name

  user_data = templatefile("${path.module}/user_data.sh", {
    openvpn_users = join(" ", var.openvpn_users)
    routes        = join(" ", var.routes)
  })
  user_data_replace_on_change = true
  tags = {
    Name = "OpenVPN-Server"
  }
}

# Create Lambda function package
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/ssm_automation_lambda.zip"
  source {
    content = templatefile("${path.module}/lambda_function.py", {
      instance_id = aws_instance.openvpn_server.id
    })
    filename = "lambda_function.py"
  }
}

# IAM role for Lambda function
resource "aws_iam_role" "lambda_execution_role" {
  name = "openvpn-ssm-automation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda to execute SSM commands
resource "aws_iam_role_policy" "lambda_ssm_policy" {
  name = "openvpn-ssm-automation-policy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceInformation",
          "ssm:GetDocument",
          "ssm:DescribeDocumentParameters",
          "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "ssm_automation" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "openvpn-ssm-automation"
  role            = aws_iam_role.lambda_execution_role.arn
  handler         = "lambda_function.lambda_handler"
  runtime         = "python3.9"
  timeout         = 300

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      OPENVPN_INSTANCE_ID = aws_instance.openvpn_server.id
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_ssm_policy,
    aws_cloudwatch_log_group.lambda_logs
  ]
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/openvpn-ssm-automation"
  retention_in_days = 14
}

# EventBridge rule to detect SSM document changes
resource "aws_cloudwatch_event_rule" "ssm_document_changes" {
  name        = "openvpn-ssm-document-changes"
  description = "Capture SSM document changes for OpenVPN automation"

  event_pattern = jsonencode({
    source        = ["aws.ssm"]
    detail-type   = ["SSM Document State Change"]
    detail = {
      document-name = [
        {
          prefix = "OpenVPN-"
        }
      ]
      state = ["Active"]
    }
  })
}

# EventBridge target to trigger Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.ssm_document_changes.name
  target_id = "TriggerLambdaFunction"
  arn       = aws_lambda_function.ssm_automation.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ssm_automation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ssm_document_changes.arn
}

# SSM Document for OpenVPN user management
resource "aws_ssm_document" "openvpn_user_management" {
  name            = "OpenVPN-UserManagement"
  document_type   = "Command"
  document_format = "YAML"

  content = file("${path.module}/openvpn-user-management.yaml")

  tags = {
    Environment = "openvpn"
    Purpose     = "automation"
  }
}

output "openvpn_public_ip" {
  value = aws_instance.openvpn_server.public_ip
}
