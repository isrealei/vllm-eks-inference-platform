apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-a10g
spec:
  amiFamily: AL2023  # Amazon Linux 2023 with GPU drivers
  amiSelectorTerms:
    - alias: al2023@latest                # Amazon Linux 2 with GPU drivers
  role: ${NODE_ROLE}       # replace with your node IAM role
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"  
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"   
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        deleteOnTermination: true
  tags:
    purpose: gpu-testing
    node-type: gpu-a10g