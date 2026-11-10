mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

mock_data "aws_region" {
  defaults = {
    id     = "us-east-1"
    name   = "us-east-1"
    region = "us-east-1"
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    user_id    = "AIDATEST"
  }
}

mock_data "aws_elb_service_account" {
  defaults = {
    arn = "arn:aws:iam::127311923021:root"
    id  = "127311923021"
  }
}

mock_data "aws_partition" {
  defaults = {
    dns_suffix         = "amazonaws.com"
    id                 = "aws"
    partition          = "aws"
    reverse_dns_prefix = "com.amazonaws"
  }
}

mock_data "aws_iam_policy_document" {
  defaults = {
    json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

mock_resource "aws_cloudfront_function" {
  defaults = {
    arn = "arn:aws:cloudfront::123456789012:function/honua-console"
  }
}

mock_resource "aws_lb" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/honua-test/0000000000000000"
  }
}

mock_resource "aws_lb_target_group" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-test/0000000000000000"
  }
}

mock_resource "aws_lb_listener" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/honua-test/0000000000000000/1111111111111111"
  }
}

mock_resource "aws_iam_policy" {
  defaults = {
    arn = "arn:aws:iam::123456789012:policy/honua-test"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::123456789012:role/honua-test"
  }
}

mock_resource "aws_cloudfront_distribution" {
  defaults = {
    id  = "E2EXAMPLE1234"
    arn = "arn:aws:cloudfront::123456789012:distribution/E2EXAMPLE1234"
  }
}

mock_data "aws_iam_role" {
  defaults = {
    name = "retained-controller"
    arn  = "arn:aws:iam::123456789012:role/retained-controller"
  }
}
