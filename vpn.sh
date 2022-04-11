#!/usr/bin/bash

# Global variables
ipsec_psk='Microsoft123'

#########
# Azure #
#########

# Variables
rg=multicloud
location=eastus
vnet_name=azure
vnet_prefix=192.168.0.0/16
gateway_subnet_prefix=192.168.1.0/24
vm_subnet_prefix=192.168.2.0/24
vm_sku=Standard_B1s
vpngw_name=vpngw
vpngw_asn=65001

# Create RG and VNets
az group create -n "$rg" -l "$location"
az network vnet create -g "$rg" -n "$vnet_name" --address-prefix "$vnet_prefix" -l "$location"
az network vnet subnet create -g "$rg" -n GatewaySubnet --vnet-name "$vnet_name" --address-prefix "$gateway_subnet_prefix"
az network vnet subnet create -g "$rg" -n vm --vnet-name "$vnet_name" --address-prefix "$vm_subnet_prefix"

# Create test VM
az vm create -n testvm -g $rg --image UbuntuLTS --generate-ssh-keys --size $vm_sku -l $location \
   --vnet-name $vnet_name --subnet vm --public-ip-address vmtest-pip --public-ip-sku Standard

# Create PIPs and VNGs
az network public-ip create -g "$rg" -n ergw-pip --allocation-method Dynamic --sku Basic -l "$location" -o none
az network public-ip create -g "$rg" -n vpngw-a-pip --allocation-method Dynamic --sku Basic -l "$location" -o none
az network public-ip create -g "$rg" -n vpngw-b-pip --allocation-method Dynamic --sku Basic -l "$location" -o none
az network vnet-gateway create -g "$rg" --sku VpnGw1 --gateway-type Vpn --vpn-type RouteBased --vnet $vnet_name -n $vpngw_name --public-ip-addresses vpngw-a-pip vpngw-b-pip --asn "$vpngw_asn"
vpngw_pip_0=$(az network vnet-gateway show -n "$vpngw_name" -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv) && echo "$vpngw_pip_0"
vpngw_private_ip_0=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv) && echo "$vpngw_private_ip_0"
vpngw_pip_1=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv) && echo "$vpngw_pip_1"
vpngw_private_ip_1=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv) && echo "$vpngw_private_ip_1"
vpngw_asn=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.asn' -o tsv) && echo "$vpngw_asn"

# Logs
logws_name=$(az monitor log-analytics workspace list -g $rg --query "[?location=='${location}'].name" -o tsv)
if [[ -z "$logws_name" ]]
then
    logws_name=log$RANDOM
    echo "INFO: Creating log analytics workspace ${logws_name} in ${location}..."
    az monitor log-analytics workspace create -n $logws_name -g $rg -l $location -o none
else
    echo "INFO: Log Analytics workspace $logws_name in $location found in resource group $rg"
fi
logws_id=$(az resource list -g $rg -n $logws_name --query '[].id' -o tsv)
logws_customerid=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
vpngw_id=$(az network vnet-gateway show -n $vpngw_name -g $rg --query id -o tsv)
az monitor diagnostic-settings create -n vpndiag --resource "$vpngw_id" --workspace "$logws_id" \
    --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
    --logs '[{"category": "GatewayDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
            {"category": "TunnelDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
            {"category": "RouteDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
            {"category": "IKEDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' -o none


#######
# AWS #
#######

# Variables
sg_name=multicloudsg
kp_name=joseaws
instance_size='t2.nano'
instance_image=ami-'059cd2be9c27a0e81'
# instance_image=ami-a4827dc9
vpc_prefix='172.16.0.0/16'
subnet1_prefix='172.16.1.0/24'
subnet2_prefix='172.16.2.0/24'
vgw_asn=65002
ipsec_startup_action='start'

# Create Key Pair if not there
kp_id=$(aws ec2 describe-key-pairs --key-name "$kp_name" --query 'KeyPairs[0].KeyPairId' --output text)
if [[ -z "$kp_id" ]]; then
    echo "Key pair $kp_name does not exist, creating new..."
    pemfile="$HOME/.ssh/${kp_name}.pem"
    touch "$pemfile"
    aws ec2 create-key-pair --key-name $kp_name --key-type rsa --query 'KeyMaterial' --output text > "$pemfile"
    chmod 400 "$pemfile"
else
    echo "Key pair $kp_name already exists with ID $kp_id"
fi

# VPC and subnet
# https://docs.aws.amazon.com/vpc/latest/userguide/vpc-subnets-commands-example.html
vpc_id=$(aws ec2 create-vpc --cidr-block "$vpc_prefix" --query Vpc.VpcId --output text)
zone1_id=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneId' --output text)
zone2_id=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneId' --output text)
subnet1_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$subnet1_prefix" --availability-zone-id "$zone1_id" --query Subnet.SubnetId --output text)
subnet2_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$subnet2_prefix" --availability-zone-id "$zone2_id" --query Subnet.SubnetId --output text)
igw_id=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
if [[ -n "$igw_id" ]]; then
    aws ec2 attach-internet-gateway --vpc-id "$vpc_id" --internet-gateway-id "$igw_id"
fi
aws ec2 modify-subnet-attribute --subnet-id "$subnet1_id" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$subnet2_id" --map-public-ip-on-launch

# If subnet and VPC already existed
vpc_id=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$vpc_prefix" --query 'Vpcs[0].VpcId' --output text)
subnet1_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=cidr-block,Values=$subnet1_prefix" --query 'Subnets[0].SubnetId' --output text)
subnet2_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=cidr-block,Values=$subnet2_prefix" --query 'Subnets[0].SubnetId' --output text)

# Route table
rt_id=$(aws ec2 create-route-table --vpc-id "$vpc_id" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id "$rt_id" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw_id"
aws ec2 associate-route-table --subnet-id "$subnet1_id" --route-table-id "$rt_id"
aws ec2 associate-route-table --subnet-id "$subnet2_id" --route-table-id "$rt_id"

# Create SG
aws ec2 create-security-group --group-name $sg_name --description "Test SG" --vpc-id "$vpc_id"
sg_id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg_name" --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0

# Create instances
aws ec2 run-instances --image-id "$instance_image" --key-name "$kp_name" --security-group-ids "$sg_id" --instance-type "$instance_size" --subnet-id "$subnet1_id"
aws ec2 run-instances --image-id "$instance_image" --key-name "$kp_name" --security-group-ids "$sg_id" --instance-type "$instance_size" --subnet-id "$subnet2_id"
# aws ec2 run-instances  --image-id ami-5ec1673e --key-name MyKey --security-groups EC2SecurityGroup --instance-type t2.micro --placement AvailabilityZone=us-west-2b --block-device-mappings DeviceName=/dev/sdh,Ebs={VolumeSize=100} --count 2
instance1_id=$(aws ec2 describe-instances --filters "Name=subnet-id,Values=$subnet1_id" --query 'Reservations[0].Instances[0].InstanceId' --output text)
instance2_id=$(aws ec2 describe-instances --filters "Name=subnet-id,Values=$subnet2_id" --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Check SSH access
instance1_pip=$(aws ec2 describe-instances --instance-id "$instance1_id" --query 'Reservations[*].Instances[*].PublicIpAddress' --output text) && echo "$instance1_pip"
instance2_pip=$(aws ec2 describe-instances --instance-id "$instance2_id" --query 'Reservations[*].Instances[*].PublicIpAddress' --output text) && echo "$instance2_pip"
pemfile="$HOME/.ssh/${kp_name}.pem"
user=ec2-user
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -i "$pemfile" "${user}@${instance1_pip}" "ip a"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -i "$pemfile" "${user}@${instance2_pip}" "ip a"

# Create CGWs for Azure (2 required)
# cgw_type=$(aws ec2 get-vpn-connection-device-types --query 'VpnConnectionDeviceTypes[?starts_with(Vendor,`Generic`)]|[0].VpnConnectionDeviceTypeId' --output text)
aws ec2 create-customer-gateway --bgp-asn "$vpngw_asn" --public-ip "$vpngw_pip_0" --device-name vpngw-0 --type 'ipsec.1'
aws ec2 create-customer-gateway --bgp-asn "$vpngw_asn" --public-ip "$vpngw_pip_1" --device-name vpngw-1 --type 'ipsec.1'

# Create VGW and attach to VPC
vgw_id=$(aws ec2 create-vpn-gateway --type 'ipsec.1' --amazon-side-asn $vgw_asn --query 'VpnGateway.VpnGatewayId' --output text)
vpc_id=$(aws ec2 describe-vpcs --filters "Name=cidr-block,Values=$vpc_prefix" --query 'Vpcs[0].VpcId' --output text) && echo "$vpc_id"
aws ec2 attach-vpn-gateway --vpn-gateway-id "$vgw_id" --vpc-id "$vpc_id"
aws ec2 describe-vpcs --vpc-id "$vpc_id"
rt_id=$(aws ec2 describe-route-tables --query 'RouteTables[*].Associations[?SubnetId==`'$subnet1_id'`].RouteTableId' --output text)
aws ec2 enable-vgw-route-propagation --gateway-id "$vgw_id" --route-table-id "$rt_id"

# Create 2 tunnels, one to each CGW
cgw0_id=$(aws ec2 describe-customer-gateways --filters "Name=device-name,Values=vpngw-0" --query 'CustomerGateways[*].CustomerGatewayId' --output text)
cgw1_id=$(aws ec2 describe-customer-gateways --filters "Name=device-name,Values=vpngw-1" --query 'CustomerGateways[*].CustomerGatewayId' --output text)
vpncx0_options="{\"TunnelOptions\": [ 
    {\"TunnelInsideCidr\": \"169.254.21.0/30\", \"PreSharedKey\": \"$ipsec_psk\", \"StartupAction\": \"$ipsec_startup_action\" },
    {\"TunnelInsideCidr\": \"169.254.21.4/30\", \"PreSharedKey\": \"$ipsec_psk\", \"StartupAction\": \"$ipsec_startup_action\" } 
    ] }"
vpncx1_options="{\"TunnelOptions\": [ 
    {\"TunnelInsideCidr\": \"169.254.22.0/30\", \"PreSharedKey\": \"$ipsec_psk\", \"StartupAction\": \"$ipsec_startup_action\" },
    {\"TunnelInsideCidr\": \"169.254.22.4/30\", \"PreSharedKey\": \"$ipsec_psk\", \"StartupAction\": \"$ipsec_startup_action\" } 
    ] }"
aws ec2 create-vpn-connection --vpn-gateway-id "$vgw_id" --customer-gateway-id "$cgw0_id" --type 'ipsec.1' --options "$vpncx0_options"
aws ec2 create-vpn-connection --vpn-gateway-id "$vgw_id" --customer-gateway-id "$cgw1_id" --type 'ipsec.1' --options "$vpncx1_options"

# Get public and private IPs for each connection (each connection has 2 tunnels)
vpncx0_id=$(aws ec2 describe-vpn-connections --filters "Name=customer-gateway-id,Values=$cgw0_id" --query 'VpnConnections[0].VpnConnectionId' --output text)
vpncx1_id=$(aws ec2 describe-vpn-connections --filters "Name=customer-gateway-id,Values=$cgw1_id" --query 'VpnConnections[0].VpnConnectionId' --output text)
aws0toaz0_pip=$(aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[0].Options.TunnelOptions[0].OutsideIpAddress' --output text)
while [[ "$aws0toaz0" == "None" ]]; do
    sleep 30
    aws0toaz0_pip=$(aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[0].Options.TunnelOptions[0].OutsideIpAddress' --output text)
done
aws1toaz0_pip=$(aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[0].Options.TunnelOptions[1].OutsideIpAddress' --output text)
aws0toaz1_pip=$(aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx1_id" --query 'VpnConnections[0].Options.TunnelOptions[0].OutsideIpAddress' --output text)
aws1toaz1_pip=$(aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx1_id" --query 'VpnConnections[0].Options.TunnelOptions[1].OutsideIpAddress' --output text)
echo "Public IP addresses allocated to the tunnels: $aws0toaz0_pip, $aws0toaz1_pip, $aws1toaz0_pip, $aws1toaz1_pip"
# aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[0].Options.TunnelOptions[0].TunnelInsideCidr' --output text
# aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[0].Options.TunnelOptions[0].PreSharedKey' --output text

#########
# Azure #
#########

# For stuff we need to do over REST
azvpn_api_version="2022-01-01"

# Create LNGs, update VNG with custom BGP IP addresses (aka APIPAs) and create connections
az network vnet-gateway update -n "$vpngw_name" -g $rg \
    --set 'bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses=["169.254.21.2", "169.254.21.6"]' \
    --set 'bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses=["169.254.22.2", "169.254.22.6"]'

# Create LNGs
az network local-gateway create -g $rg -n aws00 --gateway-ip-address "$aws0toaz0_pip" --asn "$vgw_asn" --bgp-peering-address '169.254.21.1' --peer-weight 0 -l $location
az network local-gateway create -g $rg -n aws01 --gateway-ip-address "$aws0toaz1_pip" --asn "$vgw_asn" --bgp-peering-address '169.254.22.1' --peer-weight 0 -l $location
az network local-gateway create -g $rg -n aws10 --gateway-ip-address "$aws1toaz0_pip" --asn "$vgw_asn" --bgp-peering-address '169.254.21.5' --peer-weight 0 -l $location
az network local-gateway create -g $rg -n aws11 --gateway-ip-address "$aws1toaz1_pip" --asn "$vgw_asn" --bgp-peering-address '169.254.22.5' --peer-weight 0 -l $location

# Get VNG ipconfig IDs
vpngw_config0_id=$(az network vnet-gateway show -n $vpngw_name -g $rg --query 'ipConfigurations[0].id' -o tsv)
vpngw_config1_id=$(az network vnet-gateway show -n $vpngw_name -g $rg --query 'ipConfigurations[1].id' -o tsv)

# Create connection: AWS00 (VPNGW0 - AWS0)
az network vpn-connection create -g $rg --shared-key "$ipsec_psk" --enable-bgp -n aws00 --vnet-gateway1 $vpngw_name --local-gateway2 'aws00' -o none
# az network vpn-connection update -g $rg -n aws00 --set 'connectionMode=ResponderOnly' -o none
# az network vpn-connection update -g $rg -n aws00 --set 'connectionMode=Default' -o none
aws00cx_id=$(az network vpn-connection show -n aws00 -g $rg --query id -o tsv)
aws00cx_json=$(az rest --method GET --uri "${aws00cx_id}?api-version=${azvpn_api_version}")
custom_ip_json='[{"customBgpIpAddress": "169.254.21.2", "ipConfigurationId": "'$vpngw_config0_id'"},{"customBgpIpAddress": "169.254.22.2", "ipConfigurationId": "'$vpngw_config1_id'"}]'
aws00cx_json_updated=$(echo "$aws00cx_json" | jq ".properties.gatewayCustomBgpIpAddresses=$custom_ip_json")
az rest --method PUT --uri "${aws00cx_id}?api-version=${azvpn_api_version}" --body "$aws00cx_json_updated" -o none

# Create connection: AWS01 (VPNGW1 - AWS0)
az network vpn-connection create -g $rg --shared-key "$ipsec_psk" --enable-bgp -n aws01 --vnet-gateway1 $vpngw_name --local-gateway2 'aws01' -o none
# az network vpn-connection update -g $rg -n aws01 --set 'connectionMode=ResponderOnly' -o none
# az network vpn-connection update -g $rg -n aws01 --set 'connectionMode=Default' -o none
aws01cx_id=$(az network vpn-connection show -n aws01 -g $rg --query id -o tsv)
aws01cx_json=$(az rest --method GET --uri "${aws01cx_id}?api-version=${azvpn_api_version}")
custom_ip_json='[{"customBgpIpAddress": "169.254.21.2", "ipConfigurationId": "'$vpngw_config0_id'"},{"customBgpIpAddress": "169.254.22.2", "ipConfigurationId": "'$vpngw_config1_id'"}]'
aws01cx_json_updated=$(echo "$aws01cx_json" | jq ".properties.gatewayCustomBgpIpAddresses=$custom_ip_json")
az rest --method PUT --uri "${aws01cx_id}?api-version=${azvpn_api_version}" --body "$aws01cx_json_updated" -o none

# Create connection: AWS10 (VPNGW0 - AWS1)
az network vpn-connection create -g $rg --shared-key "$ipsec_psk" --enable-bgp -n aws10 --vnet-gateway1 $vpngw_name --local-gateway2 'aws10' -o none
# az network vpn-connection update -g $rg -n aws10 --set 'connectionMode=ResponderOnly' -o none
# az network vpn-connection update -g $rg -n aws10 --set 'connectionMode=Default' -o none
aws10cx_id=$(az network vpn-connection show -n aws10 -g $rg --query id -o tsv)
aws10cx_json=$(az rest --method GET --uri "${aws10cx_id}?api-version=${azvpn_api_version}")
custom_ip_json='[{"customBgpIpAddress": "169.254.21.6", "ipConfigurationId": "'$vpngw_config0_id'"},{"customBgpIpAddress": "169.254.22.6", "ipConfigurationId": "'$vpngw_config1_id'"}]'
aws10cx_json_updated=$(echo "$aws10cx_json" | jq ".properties.gatewayCustomBgpIpAddresses=$custom_ip_json")
az rest --method PUT --uri "${aws10cx_id}?api-version=${azvpn_api_version}" --body "$aws10cx_json_updated" -o none

# Create connection: AWS11 (VPNGW1 - AWS1)
az network vpn-connection create -g $rg --shared-key "$ipsec_psk" --enable-bgp -n aws11 --vnet-gateway1 $vpngw_name --local-gateway2 'aws11' -o none
# az network vpn-connection update -g $rg -n aws11 --set 'connectionMode=ResponderOnly' -o none
# az network vpn-connection update -g $rg -n aws11 --set 'connectionMode=Default' -o none
aws11cx_id=$(az network vpn-connection show -n aws11 -g $rg --query id -o tsv)
aws11cx_json=$(az rest --method GET --uri "${aws11cx_id}?api-version=${azvpn_api_version}")
custom_ip_json='[{"customBgpIpAddress": "169.254.21.6", "ipConfigurationId": "'$vpngw_config0_id'"},{"customBgpIpAddress": "169.254.22.6", "ipConfigurationId": "'$vpngw_config1_id'"}]'
aws11cx_json_updated=$(echo "$aws11cx_json" | jq ".properties.gatewayCustomBgpIpAddresses=$custom_ip_json")
az rest --method PUT --uri "${aws11cx_id}?api-version=${azvpn_api_version}" --body "$aws11cx_json_updated" -o none


##########
# Google #
##########

# Variables
gcp_project_name=multicloud
gcp_project_id="${gcp_project_name}${RANDOM}"
gcp_vm_name=myvm
gcp_machine_type=e2-micro
gcp_region=us-east1
gcp_zone=us-east1-c
gcp_vpc_name=multicloud
gcp_subnet_name=web
gcp_subnet_prefix='10.0.1.0/24'
gcp_gw_name=vpngw
gcp_router_name=router
gcp_asn=65003

# Get environment info
gcp_billing_account=$(gcloud beta billing accounts list --format json | jq -r '.[0].name')
gcp_billing_account_short=$(echo "$gcp_billing_account" | cut -f 2 -d/) && echo "$gcp_billing_account_short"

# Create project
gcloud projects create $gcp_project_id --name $gcp_project_name
gcloud config set project $gcp_project_id
gcloud config set compute/region $gcp_region
sleep 30    # This takes a while
gcloud beta billing projects link "$gcp_project_id" --billing-account "$gcp_billing_account_short"
gcloud services enable compute.googleapis.com

# Delete default VPC
gcloud compute firewall-rules delete default-allow-rdp --quiet
gcloud compute firewall-rules delete default-allow-icmp --quiet
gcloud compute firewall-rules delete default-allow-internal --quiet
gcloud compute firewall-rules delete default-allow-ssh --quiet
gcloud compute networks delete default --quiet

# Create custom VPC
gcloud compute networks create $gcp_vpc_name --bgp-routing-mode=regional --mtu=1500 --subnet-mode=custom
gcloud compute networks subnets create $gcp_subnet_name --network $gcp_vpc_name --range $gcp_subnet_prefix --region=$gcp_region
gcloud compute firewall-rules create multicloud-allow-icmp-192-168 --network $gcp_vpc_name \
    --priority=1000 --direction=INGRESS --rules=icmp --source-ranges=192.168.0.0/16 --action=ALLOW
# Other examples:
# gcloud compute firewall-rules create <FIREWALL_NAME> --network $gcp_vpc_name --allow tcp,udp,icmp --source-ranges <IP_RANGE>
# gcloud compute firewall-rules create <FIREWALL_NAME> --network $gcp_vpc_name --allow tcp:22,tcp:3389,icmp

# Create instance
gcloud compute images list --format json | jq -r '.[] | select(.family | contains("ubuntu-2004-lts")) | {id,family,name,status}|join("\t")'
gcp_image_id=$(gcloud compute images list --format json | jq -r '.[] | select(.family | contains("ubuntu-2004-lts")).id') && echo $gcp_image_id
gcp_image_name=$(gcloud compute images list --format json | jq -r '.[] | select(.family | contains("ubuntu-2004-lts")).name') && echo $gcp_image_name
gcloud compute instances create $gcp_vm_name --image-family=ubuntu-2004-lts --image-project=ubuntu-os-cloud --machine-type $gcp_machine_type --network $gcp_vpc_name \
    --subnet $gcp_subnet_name --zone $gcp_zone

# Create VPN gateway
gcloud compute vpn-gateways create $gcp_gw_name --network $gcp_vpc_name --region $gcp_region
gcp_gw_id=$(gcloud compute vpn-gateways describe $gcp_gw_name --region $gcp_region --format json | jq -r '.id') && echo "$gcp_gw_id"
gcp_gw_pip0=$(gcloud compute vpn-gateways describe $gcp_gw_name --region $gcp_region --format json | jq -r '.vpnInterfaces[0].ipAddress') && echo "$gcp_gw_pip0"
gcp_gw_pip1=$(gcloud compute vpn-gateways describe $gcp_gw_name --region $gcp_region --format json | jq -r '.vpnInterfaces[1].ipAddress') && echo "$gcp_gw_pip1"

# Create peer VPN gateways for Azure
gcloud compute external-vpn-gateways create azvpngw --interfaces "0=${vpngw_pip_0},1=${vpngw_pip_1}"

# Create router
gcloud compute routers create "$gcp_router_name" --region=$gcp_region --network=$gcp_vpc_name --asn=$gcp_asn

# Add additional APIPAs to VNG
az network vnet-gateway update -n "$vpngw_name" -g $rg \
    --set 'bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses=["169.254.21.2", "169.254.21.6", "169.254.21.130"]' \
    --set 'bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses=["169.254.22.2", "169.254.22.6", "169.254.22.130"]'

# Create tunnels (GCP side)
gcloud compute vpn-tunnels create azvpngw0 \
   --peer-external-gateway=azvpngw \
   --peer-external-gateway-interface=0  \
   --region=$gcp_region \
   --ike-version=2 \
   --shared-secret=$ipsec_psk \
   --router=$gcp_router_name \
   --vpn-gateway=$gcp_gw_name \
   --interface=0
gcloud compute vpn-tunnels create azvpngw1 \
   --peer-external-gateway=azvpngw \
   --peer-external-gateway-interface=1  \
   --region=$gcp_region \
   --ike-version=2 \
   --shared-secret=$ipsec_psk \
   --router=$gcp_router_name \
   --vpn-gateway=$gcp_gw_name \
   --interface=1

# Create router interfaces
# vng0_bgp_ip=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
# vng1_bgp_ip=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
gcloud compute routers add-interface $gcp_router_name --region=$gcp_region \
   --interface-name=azvpngw0 --ip-address 169.254.21.129 --mask-length=30 --vpn-tunnel=azvpngw0
gcloud compute routers add-bgp-peer $gcp_router_name --interface=azvpngw0 --region=$gcp_region \
   --peer-name=azvpngw0 --peer-ip-address=169.254.21.130 --peer-asn="$vpngw_asn"
gcloud compute routers add-interface $gcp_router_name --region=$gcp_region \
   --interface-name=azvpngw1 --ip-address 169.254.22.129 --mask-length=30 --vpn-tunnel=azvpngw1
gcloud compute routers add-bgp-peer $gcp_router_name --interface=azvpngw1 --region=$gcp_region \
   --peer-name=azvpngw1  --peer-ip-address=169.254.22.130 --peer-asn="$vpngw_asn"

# If you need to delete the interfaces/peers
# gcloud compute routers remove-interface $gcp_router_name --interface-name azvpngw0
# gcloud compute routers remove-bgp-peer $gcp_router_name --peer-name azvpngw0
# gcloud compute routers remove-interface $gcp_router_name --interface-name azvpngw1
# gcloud compute routers remove-bgp-peer $gcp_router_name --peer-name azvpngw1

# Create LNGs and connections (Azure side)
az network local-gateway create -g $rg -n gcp0 --gateway-ip-address "$gcp_gw_pip0" --asn "$gcp_asn" --bgp-peering-address '169.254.21.129' --peer-weight 0 -l $location
az network local-gateway create -g $rg -n gcp1 --gateway-ip-address "$gcp_gw_pip1" --asn "$gcp_asn" --bgp-peering-address '169.254.22.129' --peer-weight 0 -l $location
az network vpn-connection create -g $rg --shared-key "$ipsec_psk" --enable-bgp -n gcp0 --vnet-gateway1 $vpngw_name --local-gateway2 gcp0 -o none
az network vpn-connection create -g $rg --shared-key "$ipsec_psk" --enable-bgp -n gcp1 --vnet-gateway1 $vpngw_name --local-gateway2 gcp1 -o none

# Update Azure connections to use right APIPA as source
gcp0cx_id=$(az network vpn-connection show -n gcp0 -g $rg --query id -o tsv)
gcp0cx_json=$(az rest --method GET --uri "${gcp0cx_id}?api-version=${azvpn_api_version}")
custom_ip_json='[{"customBgpIpAddress": "169.254.21.130", "ipConfigurationId": "'$vpngw_config0_id'"},{"customBgpIpAddress": "169.254.22.130", "ipConfigurationId": "'$vpngw_config1_id'"}]'
gcp0cx_json_updated=$(echo "$gcp0cx_json" | jq ".properties.gatewayCustomBgpIpAddresses=$custom_ip_json")
az rest --method PUT --uri "${gcp0cx_id}?api-version=${azvpn_api_version}" --body "$gcp0cx_json_updated" -o none
gcp1cx_id=$(az network vpn-connection show -n gcp1 -g $rg --query id -o tsv)
gcp1cx_json=$(az rest --method GET --uri "${gcp1cx_id}?api-version=${azvpn_api_version}")
custom_ip_json='[{"customBgpIpAddress": "169.254.21.130", "ipConfigurationId": "'$vpngw_config0_id'"},{"customBgpIpAddress": "169.254.22.130", "ipConfigurationId": "'$vpngw_config1_id'"}]'
gcp1cx_json_updated=$(echo "$gcp1cx_json" | jq ".properties.gatewayCustomBgpIpAddresses=$custom_ip_json")
az rest --method PUT --uri "${gcp1cx_id}?api-version=${azvpn_api_version}" --body "$gcp1cx_json_updated" -o none


###############
# Diagnostics #
###############

az network vnet-gateway show -n "$vpngw_name" -g "$rg"
az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses' -o tsv
az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses' -o tsv
az network vnet-gateway list-bgp-peer-status -n $vpngw_name -g $rg -o table
vng0_bgp_ip=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
vng1_bgp_ip=$(az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
az network vnet-gateway list-bgp-peer-status -n $vpngw_name -g $rg -o table --query 'value[?localAddress == `'$vng0_bgp_ip'`]'
az network vnet-gateway list-bgp-peer-status -n $vpngw_name -g $rg -o table --query 'value[?localAddress == `'$vng1_bgp_ip'`]'
az network local-gateway list -g "$rg" -o table
az network vpn-connection list -g "$rg" -o table
az network vpn-connection list -g "$rg" -o table --query '[].{Name:name,EgressBytes:egressBytesTransferred,IngressBytes:ingressBytesTransferred,Mode:connectionMode,Status:tunnelConnectionStatus[0].connectionStatus,TunnelName:tunnelConnectionStatus[0].tunnel}'
az network vpn-connection show -n aws00 -g "$rg"
az rest --method GET --uri "$(az network vpn-connection show -n aws00 -g $rg --query id -o tsv)?api-version=$azvpn_api_version"

aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock]' --output text
aws ec2 describe-vpcs --vpc-id "$vpc_id"
aws ec2 describe-subnets --query 'Subnets[].[SubnetId,CidrBlock,VpcId]' --output text
aws ec2 describe-subnets --query 'Subnets[?VpcId==`'$vpc_id'`].[SubnetId,CidrBlock,VpcId]' --output text
aws ec2 describe-subnets --subnet-id "$subnet1_id"
aws ec2 describe-subnets --subnet-id "$subnet2_id"
aws ec2 describe-route-tables --query 'RouteTables[].[RouteTableId,VpcId]' --output text
aws ec2 describe-route-tables --query 'RouteTables[?VpcId==`'$vpc_id'`].[RouteTableId,VpcId]' --output text
aws ec2 describe-route-tables --query 'RouteTables[*].Associations[?SubnetId==`'$subnet1_id'`].[RouteTableId,SubnetId]' --output text
aws ec2 describe-route-tables --query 'RouteTables[*].Associations[?SubnetId==`'$subnet2_id'`].[RouteTableId,SubnetId]' --output text
aws ec2 describe-route-tables --query 'RouteTables[*].Routes[].[State,DestinationCidrBlock,Origin,GatewayId]' --output text
aws ec2 describe-vpn-gateways --query 'VpnGateways[*].[VpnGatewayId,State,AmazonSideAsn,VpcAttachments[0].VpcId]' --output text
aws ec2 describe-vpn-connections --query 'VpnConnections[*].[VpnConnectionId,VpnGatewayId,CustomerGatewayId,State]' --output text
aws ec2 describe-vpn-connections --query 'VpnConnections[*].VgwTelemetry[*].[OutsideIpAddress,StatusMessage,Status]' --output text
aws ec2 describe-customer-gateways --query 'CustomerGateways[*].[CustomerGatewayId,DeviceName,BgpAsn,IpAddress,State]' --output text
aws ec2 describe-security-groups --group-names "$sg_name"

# Tunnel AzVPNGW0 <-> AWS VGW0
az network vnet-gateway show -n $vpngw_name -g $rg --query '{PIP0:bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0],IP00:bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses[0],IP01:bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses[1],ASN:bgpSettings.asn}' -o tsv
az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses[0]' -o tsv
az network vpn-connection show -n aws00 -g "$rg" --query '{Name:name,Mode:connectionMode,Status:connectionStatus}' -o tsv
az rest --method GET --uri "${aws00cx_id}?api-version=${azvpn_api_version}" --query '{Name:name,Mode:properties.connectionMode,Status:properties.connectionStatus,BgpIP:properties.gatewayCustomBgpIpAddresses[0].customBgpIpAddress}' -o tsv
az network local-gateway show -n aws00 -g "$rg" --query '{PIP:gatewayIpAddress,IP:bgpSettings.bgpPeeringAddress,ASN:bgpSettings.asn}' -o tsv
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[*].Options.TunnelOptions[0].[OutsideIpAddress,TunnelInsideCidr,StartupAction]' --output text
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[*].VgwTelemetry[0].[OutsideIpAddress,StatusMessage,Status]' --output text

# Tunnel AzVPNGW1 <-> AWS VGW0
az network vnet-gateway show -n $vpngw_name -g $rg --query '{PIP1:bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0],IP10:bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses[0],IP11:bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses[1],ASN:bgpSettings.asn}' -o tsv
az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses[0]' -o tsv
az network vpn-connection show -n aws01 -g "$rg" --query '{Name:name,Mode:connectionMode,Status:connectionStatus}' -o tsv
az rest --method GET --uri "${aws01cx_id}?api-version=${azvpn_api_version}" --query '{Name:name,Mode:properties.connectionMode,Status:properties.connectionStatus,BgpIP:properties.gatewayCustomBgpIpAddresses[1].customBgpIpAddress}' -o tsv
az network local-gateway show -n aws01 -g "$rg" --query '{PIP:gatewayIpAddress,IP:bgpSettings.bgpPeeringAddress,ASN:bgpSettings.asn}' -o tsv
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx1_id" --query 'VpnConnections[*].Options.TunnelOptions[0].[OutsideIpAddress,TunnelInsideCidr,StartupAction]' --output text
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx1_id" --query 'VpnConnections[*].VgwTelemetry[0].[OutsideIpAddress,StatusMessage,Status]' --output text

# Tunnel AzVPNGW0 <-> AWS VGW1
az network vnet-gateway show -n $vpngw_name -g $rg --query '{PIP0:bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0],IP00:bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses[0],IP01:bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses[1],ASN:bgpSettings.asn}' -o tsv
az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[0].customBgpIpAddresses[0]' -o tsv
az network vpn-connection show -n aws10 -g "$rg" --query '{Name:name,Mode:connectionMode,Status:connectionStatus}' -o tsv
az rest --method GET --uri "${aws10cx_id}?api-version=${azvpn_api_version}" --query '{Name:name,Mode:properties.connectionMode,Status:properties.connectionStatus,BgpIP:properties.gatewayCustomBgpIpAddresses[0].customBgpIpAddress}' -o tsv
az network local-gateway show -n aws10 -g "$rg" --query '{PIP:gatewayIpAddress,IP:bgpSettings.bgpPeeringAddress,ASN:bgpSettings.asn}' -o tsv
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[*].Options.TunnelOptions[1].[OutsideIpAddress,TunnelInsideCidr,StartupAction]' --output text
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx0_id" --query 'VpnConnections[*].VgwTelemetry[1].[OutsideIpAddress,StatusMessage,Status]' --output text

# Tunnel AzVPNGW1 <-> AWS VGW1
az network vnet-gateway show -n $vpngw_name -g $rg --query '{PIP1:bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0],IP10:bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses[0],IP11:bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses[1],ASN:bgpSettings.asn}' -o tsv
az network vnet-gateway show -n "$vpngw_name" -g "$rg" --query 'bgpSettings.bgpPeeringAddresses[1].customBgpIpAddresses[0]' -o tsv
az network vpn-connection show -n aws11 -g "$rg" --query '{Name:name,Mode:connectionMode,Status:connectionStatus}' -o tsv
az rest --method GET --uri "${aws11cx_id}?api-version=${azvpn_api_version}" --query '{Name:name,Mode:properties.connectionMode,Status:properties.connectionStatus,BgpIP:properties.gatewayCustomBgpIpAddresses[1].customBgpIpAddress}' -o tsv
az network local-gateway show -n aws11 -g "$rg" --query '{PIP:gatewayIpAddress,IP:bgpSettings.bgpPeeringAddress,ASN:bgpSettings.asn}' -o tsv
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx1_id" --query 'VpnConnections[*].Options.TunnelOptions[1].[OutsideIpAddress,TunnelInsideCidr,StartupAction]' --output text
aws ec2 describe-vpn-connections --vpn-connection-id "$vpncx1_id" --query 'VpnConnections[*].VgwTelemetry[1].[OutsideIpAddress,StatusMessage,Status]' --output text

# GCP

gcloud projects list
gcloud compute networks list
gcloud compute networks subnets list --network "$gcp_vpc_name"
gcloud compute vpn-gateways describe $gcp_gw_name --region $gcp_region
gcloud compute external-vpn-gateways list
gcloud compute external-vpn-gateways describe azvpngw
gcloud compute vpn-tunnels list --format json | jq -r '.[] | {name,peerIp,status,detailedStatus}|join("\t")'
gcloud compute vpn-tunnels describe azvpngw0
gcloud compute vpn-tunnels describe azvpngw1
gcloud compute routers describe "$gcp_router_name" --region $gcp_region --format json
gcloud compute routers get-status $gcp_router_name --region=$gcp_region --format='flattened(result.bgpPeerStatus[].name,result.bgpPeerStatus[].ipAddress, result.bgpPeerStatus[].peerIpAddress)'
gcloud compute routers get-status $gcp_router_name --region=$gcp_region --format=json | jq -r '.result.bestRoutesForRouter[]|{destRange,routeType,nextHopIp} | join("\t")'

gcloud compute instances describe "$gcp_vm_name"

###########
# Cleanup #
###########

# Azure
az group delete -n $rg -y --no-wait

# Google
gcloud projects delete "$gcp_project_id" --quiet

# AWS instances
instance_list=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId]' --output text)
while read -r instance_id
do
    echo "Terminating instance ${instance_id}..."
    aws ec2 terminate-instances --instance-ids "${instance_id}"
done < <(echo "$instance_list")

# AWS Connections
connection_list=$(aws ec2 describe-vpn-connections --query 'VpnConnections[*].[VpnConnectionId]' --output text)
while read -r connection_id
do
    echo "Deleting connection ${connection_id}..."
    aws ec2 delete-vpn-connection --vpn-connection-id "$connection_id"
done < <(echo "$connection_list")

# AWS CGWs
cgw_list=$(aws ec2 describe-customer-gateways --query 'CustomerGateways[*].[CustomerGatewayId]' --output text)
while read -r cgw_id
do
    echo "Deleting CGW ${cgw_id}..."
    aws ec2 delete-customer-gateway --customer-gateway-id "$cgw_id"
done < <(echo "$cgw_list")

# AWS VGWs
vgw_list=$(aws ec2 describe-vpn-gateways --query 'VpnGateways[*].[VpnGatewayId]' --output text)
while read -r vgw_id
do
    vpc_id=$(aws ec2 describe-vpn-gateways --vpn-gateway-ids $vgw_id --query 'VpnGateways[0].VpcAttachments[0].VpcId' --output text)
    echo "Detaching VGW ${vgw_id} from VPC ${vpc_id}..."
    aws ec2 detach-vpn-gateway --vpc-id "$vpc_id" --vpn-gateway-id "$vgw_id"
    echo "Deleting VGW ${vgw_id}..."
    aws ec2 delete-vpn-gateway --vpn-gateway-id "$vgw_id"
done < <(echo "$vgw_list")

# AWS SGs
sg_list=$(aws ec2 describe-security-groups --query 'SecurityGroups[*].[GroupId]' --output text)
while read -r sg_id
do
    echo "Deleting SG ${sg_id}..."
    aws ec2 delete-security-group --group-id "$sg_id"
done < <(echo "$sg_list")

# AWS Subnets
subnet_list=$(aws ec2 describe-subnets --query 'Subnets[*].[SubnetId]' --output text)
while read -r subnet_id
do
    echo "Deleting subnet ${subnet_id}..."
    aws ec2 delete-subnet --subnet-id "$subnet_id"
done < <(echo "$subnet_list")

# AWS InternetGateways
igw_list=$(aws ec2 describe-internet-gateways --query 'InternetGateways[*].[InternetGatewayId]' --output text)
while read -r igw_id
do
    echo "Deleting IGW ${igw_id}..."
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id"
done < <(echo "$igw_list")

# AWS RTs
rt_list=$(aws ec2 describe-route-tables --query 'RouteTables[*].[RouteTableId]' --output text)
while read -r rt_id
do
    echo "Deleting RT ${rt_id}..."
    aws ec2 delete-route-table --route-table-id "$rt_id"
done < <(echo "$rt_list")

# AWS VPCs
vpc_list=$(aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId]' --output text)
while read -r vpc_id
do
    echo "Deleting VPC ${vpc_id}..."
    aws ec2 delete-vpc --vpc-id "$vpc_id"
done < <(echo "$vpc_list")
