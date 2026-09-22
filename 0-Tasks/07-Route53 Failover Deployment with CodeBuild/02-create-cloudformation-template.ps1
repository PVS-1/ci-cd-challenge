[CmdletBinding()]
param(
  [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $PSScriptRoot "source"
}
$TemplatePath = Join-Path $OutputDirectory "template.yml"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Template = @'
AWSTemplateFormatVersion: '2010-09-09'
Description: Route 53 private hosted zone with primary and secondary DNS failover records.

Parameters:
  ZoneName:
    Type: String
    Description: Private hosted zone name.
  RecordName:
    Type: String
    Description: Fully qualified application DNS record name.
  PrimaryIp:
    Type: String
    Description: Public IPv4 address of the primary endpoint.
  SecondaryIp:
    Type: String
    Description: Public IPv4 address of the secondary endpoint.
  PrimaryVpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC associated with the private hosted zone.

Resources:
  PrivateHostedZone:
    Type: AWS::Route53::HostedZone
    Properties:
      Name: !Ref ZoneName
      HostedZoneConfig:
        Comment: Private hosted zone for Route 53 DNS failover.
      VPCs:
        - VPCId: !Ref PrimaryVpcId
          VPCRegion: !Ref AWS::Region

  PrimaryHealthCheck:
    Type: AWS::Route53::HealthCheck
    Properties:
      HealthCheckConfig:
        Type: HTTP
        IPAddress: !Ref PrimaryIp
        Port: 80
        ResourcePath: /
        RequestInterval: 30
        FailureThreshold: 3

  PrimaryRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref PrivateHostedZone
      Name: !Ref RecordName
      Type: A
      TTL: '60'
      ResourceRecords:
        - !Ref PrimaryIp
      SetIdentifier: primary
      Failover: PRIMARY
      HealthCheckId: !Ref PrimaryHealthCheck

  SecondaryRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      HostedZoneId: !Ref PrivateHostedZone
      Name: !Ref RecordName
      Type: A
      TTL: '60'
      ResourceRecords:
        - !Ref SecondaryIp
      SetIdentifier: secondary
      Failover: SECONDARY

Outputs:
  HostedZoneId:
    Description: Route 53 private hosted zone ID.
    Value: !Ref PrivateHostedZone
  ApplicationRecordName:
    Description: DNS record configured for failover.
    Value: !Ref RecordName
'@

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
[System.IO.File]::WriteAllText($TemplatePath, $Template, $Utf8NoBom)

Write-Output "CloudFormation template written: $TemplatePath"
Write-Output "Objective 2 complete. Template defines a private hosted zone, HTTP health check, and failover A records."