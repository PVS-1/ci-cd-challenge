terraform {
  backend "s3" {
    bucket = "cmtr-msdta2zd-bucket-cicd-tf-20260921080119"
    key    = "terraform/terraform.tfstate"
    region = "eu-west-1"
  }
}