#!/usr/bin/bash

#########################################
# Functions to consolidate output from
#   CLI commnads from different clouds
#
# Each section is composed of two types
#   of functions:
# 1. get_object_xxx: gets a certain object
#    with JSON output from cloud xxx,
#    consolidating the format
# 2. get_object: calls the previous functions
#    and joins the output
#
# Prerequisites: jq
#
# Jose Moreno, April 2022
#########################################


# VPCs
function get_vpc_aws() {
    aws ec2 describe-vpcs --output json --query 'Vpcs|[*].{prefix:CidrBlock,name:VpcId,cloud:"aws"}' | jq '.[] += {"cloud": "aws"}'
}
function get_vpc_gc() {
    aws ec2 describe-vpcs --output json --query 'Vpcs|[*].{prefix:CidrBlock,name:VpcId}'
}