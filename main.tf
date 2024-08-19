locals {
  name_suffix = "tftest"
}

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

resource "aws_s3_bucket" "content_bucket" {
  bucket = "bucket-${local.name_suffix}"
  force_destroy = true # becase content is managed in git
}

resource "aws_cloudfront_origin_access_control" "main" {
  name                              = "oac-${local.name_suffix}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "content_bucket_policy" {
  bucket = aws_s3_bucket.content_bucket.id
  policy = data.aws_iam_policy_document.content_bucket_policy.json
}

data "aws_iam_policy_document" "content_bucket_policy" {
  statement {
    sid    = ""
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = ["s3:GetObject"]

    resources = ["${aws_s3_bucket.content_bucket.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_cloudfront_distribution" "main" {
  enabled = true
  origin {
    origin_id                = aws_s3_bucket.content_bucket.id
    domain_name              = aws_s3_bucket.content_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.main.id
  }

  default_cache_behavior {
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    target_origin_id       = aws_s3_bucket.content_bucket.id
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.lambda-edge-index.qualified_arn
      include_body = false
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

resource "aws_iam_role" "lambda_edge" {
  name               = "lambda-edge-${local.name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_edge_assume_role.json
}

data "aws_iam_policy_document" "lambda_edge_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "lambda-edge-basic-role" {
  role       = aws_iam_role.lambda_edge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda-edge-index" {
  type        = "zip"
  source_dir  = "lambda_index"
  output_path = "lambda_index.zip"
}

resource "aws_lambda_function" "lambda-edge-index" {
  provider         = aws.us-east-1
  filename         = data.archive_file.lambda-edge-index.output_path
  function_name    = "lambda-edge-function-${local.name_suffix}"
  role             = aws_iam_role.lambda_edge.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.lambda-edge-index.output_base64sha256

  publish = true # add versioning
}

