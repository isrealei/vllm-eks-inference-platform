locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.team
  }
  public_subnet_tags = var.create_for_eks ? {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  } : {}

  private_subnet_tags = var.create_for_eks ? {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  } : {}

  azs = var.azs
}


# VPC and Subnets
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-vpc"
    }
  )
}

# Create public and private subnets in each availability zone
resource "aws_subnet" "public_subnets" {
  count = length(local.azs)

  vpc_id                              = aws_vpc.main.id
  availability_zone                   = local.azs[count.index]
  cidr_block                          = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch             = true
  private_dns_hostname_type_on_launch = "resource-name"
  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-public-subnet-${count.index + 1}"
    },
    local.public_subnet_tags
  )
}


resource "aws_subnet" "private_subnets" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = var.private_subnet_cidrs[count.index]
  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-private-subnet-${count.index + 1}"
    },
    local.private_subnet_tags
  )
}


# Internet Gateway, NAT Gateway, and Route Tables
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-igw"
    }
  )
}

resource "aws_eip" "nat_gw" {
  domain = "vpc"
  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-nat-gw-eip"
    }
  )

}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_gw.id
  subnet_id     = aws_subnet.public_subnets[0].id

  depends_on = [aws_internet_gateway.gw]

  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-nat-gw"
    }
  )
}


resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id

  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-public-rt"
    }
  )

}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.vpc_name}-private-rt"
    }
  )
}


# Associate route tables with subnets
resource "aws_route_table_association" "public-subnet-association" {
  count = length(aws_subnet.public_subnets)


  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private-subnet-association" {
  count = length(aws_subnet.private_subnets)

  subnet_id      = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_rt.id
}