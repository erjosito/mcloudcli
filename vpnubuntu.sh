###########################################################
# Create VPN between 2 Ubuntu VMs, one in Azure and the 
#    other one in Google Cloud
#
# Jose Moreno, October 2022
###########################################################

# Azure variables
location=westcentralus
rg=vpnnva
vm_size=Standard_B1s
vnet_name=nva
vnet_prefix=10.0.1.0/24
subnet_name=nva
subnet_prefix=10.0.1.0/26
azure_vm_name=nva01
nsg_name="${azure_vm_name}-nsg"
pip_name="${azure_vm_name}-pip"
ipsec_psk='Microsoft123!'
azure_asn=65001

# Google Cloud variables
project_name=vpnnva
project_id="${project_name}${RANDOM}"
machine_type=e2-micro
region=us-west2
zone=us-west2-b
gcp_vm_name=nva02
gcp_vpc_name=vpc
gcp_subnet_name=nva
gcp_subnet_prefix='10.0.2.0/24'
gcp_private_ip='10.0.2.2'
gcp_asn=65002
gcp_router_name=mygcprouter
gcp_router_asn=65010
# gcp_router_asn=16550

# Helper function
function first_ip(){
    subnet=$1
    IP=$(echo $subnet | cut -d/ -f 1)
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}

# Create Azure environment
echo "Creating Azure resource group..."
az group create -n $rg -l $location -o none
echo "Creating Azure virtual machine..."
az vm create -n $azure_vm_name -g $rg -l $location --image ubuntuLTS --generate-ssh-keys --nsg $nsg_name -o none \
    --public-ip-sku Standard --public-ip-address $pip_name --size $vm_size -l $location -o none \
    --vnet-name $vnet_name --vnet-address-prefix $vnet_prefix --subnet $subnet_name --subnet-address-prefix $subnet_prefix
echo "Getting IP information of Azure virtual machine..."
vm_nic_id=$(az vm show -n $azure_vm_name -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
azure_private_ip=$(az network nic show --ids $vm_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo $azure_private_ip
azure_public_ip=$(az network public-ip show -n $pip_name -g $rg --query ipAddress -o tsv) && echo $azure_public_ip
echo "Updating Azure NSG..."
az network nsg rule create -n UDP500in --nsg-name $nsg_name -g $rg --priority 1010 --destination-port-ranges 500 --access Allow --protocol Udp -o none
az network nsg rule create -n UDP4500in --nsg-name $nsg_name -g $rg --priority 1020 --destination-port-ranges 4500 --access Allow --protocol Udp -o none
echo "Trying out access to Azure VM..."
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$azure_public_ip" "ip a"

# Create Google Cloud environment
account=$(gcloud info --format json | jq -r '.config.account')
billing_account=$(gcloud beta billing accounts list --format json | jq -r '.[0].name')
billing_account_short=$(echo "$billing_account" | cut -f 2 -d/)
gcloud projects create $project_id --name $project_name
gcloud config set project $project_id
gcloud beta billing projects link "$project_id" --billing-account "$billing_account_short"
gcloud services enable compute.googleapis.com
gcloud compute networks create "$gcp_vpc_name" --bgp-routing-mode=regional --mtu=1500 --subnet-mode=custom
gcloud compute networks subnets create "$gcp_subnet_name" --network "$gcp_vpc_name" --range "$gcp_subnet_prefix" --region=$region
gcloud compute addresses create "${gcp_vm_name}-ip" --region $region --subnet $gcp_subnet_name --addresses "$gcp_private_ip"
gcloud compute instances create "$gcp_vm_name" --image-family=ubuntu-2004-lts --image-project=ubuntu-os-cloud --machine-type "$machine_type" --can-ip-forward \
      --network "$gcp_vpc_name" --subnet "$gcp_subnet_name" --private-network-ip "${gcp_vm_name}-ip" --zone "$zone"
gcloud compute firewall-rules create "${gcp_vpc_name}-allow-icmp" --network "$gcp_vpc_name" --priority=1000 --direction=INGRESS --rules=icmp --source-ranges=0.0.0.0/0 --action=ALLOW
gcloud compute firewall-rules create "${gcp_vpc_name}-allow-ssh" --network "$gcp_vpc_name" --priority=1010 --direction=INGRESS --rules=tcp:22 --source-ranges=0.0.0.0/0 --action=ALLOW
gcloud compute firewall-rules create "${gcp_vpc_name}-allow-ike" --network "$gcp_vpc_name" --priority=1020 --direction=INGRESS --rules=udp:500 --source-ranges=0.0.0.0/0 --action=ALLOW
gcloud compute firewall-rules create "${gcp_vpc_name}-allow-natt" --network "$gcp_vpc_name" --priority=1030 --direction=INGRESS --rules=udp:4500 --source-ranges=0.0.0.0/0 --action=ALLOW
gcloud compute firewall-rules create "${gcp_vpc_name}-allow-bgp" --network "$gcp_vpc_name" --priority=1030 --direction=INGRESS --rules=tcp:179 --source-ranges=10.0.0.0/8 --action=ALLOW
gcloud compute ssh $gcp_vm_name --zone=$zone --command="ip a"
gcp_private_ip=$(gcloud compute instances describe $gcp_vm_name --zone "$zone" --format=json | jq -r '.networkInterfaces[0].networkIP') && echo "$gcp_private_ip"
gcp_public_ip=$(gcloud compute instances describe $gcp_vm_name --zone $zone --format='get(networkInterfaces[0].accessConfigs[0].natIP)') && echo "$gcp_public_ip"

# Add software
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$azure_public_ip" "sudo apt update && sudo apt install -y strongswan bird"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo apt update && sudo apt install -y strongswan bird net-tools"

# VTI interfaces and static routes
# Note these changes are not reboot-persistent!!!
echo "Configuring VPN between Azure (${azure_public_ip}/${azure_private_ip}) and Google (${gcp_public_ip}/${gcp_private_ip})..."
azure_default_gw=$(first_ip $subnet_prefix)
gcp_default_gw=$(first_ip $gcp_subnet_prefix)
myip=$(curl -s4 ifconfig.co)
# Azure
echo "Creating VTI interface..."
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ip tunnel add vti0 local $azure_private_ip remote  $gcp_public_ip mode vti key 11"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo sysctl -w net.ipv4.conf.vti0.disable_policy=1"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ip link set up dev vti0"
echo "Modifying charon.conf..."
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo sed -i 's/# install_routes = yes/install_routes = no/' /etc/strongswan.d/charon.conf"
echo "Adding routes..."
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ip route add ${gcp_private_ip}/32 dev vti0"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ip route add ${gcp_public_ip}/32 via $azure_default_gw"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ip route add ${myip}/32 via $azure_default_gw" # To not lose SSH connectivity
# Google
echo "Creating VTI interface..."
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ip tunnel add vti0 local $gcp_private_ip remote  $azure_public_ip mode vti key 11"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo sysctl -w net.ipv4.conf.vti0.disable_policy=1"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ip link set up dev vti0"
echo "Modifying charon.conf..."
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo sed -i 's/# install_routes = yes/install_routes = no/' /etc/strongswan.d/charon.conf"
echo "Adding routes..."
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ip route add ${azure_private_ip}/32 dev vti0"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ip route add ${azure_public_ip}/32 via $gcp_default_gw"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ip route add ${myip}/32 via $gcp_default_gw" # To not lose SSH connectivity

# Azure: IPsec config files
vpn_psk_file=/tmp/ipsec.secrets
cat <<EOF > $vpn_psk_file
$azure_public_ip  $gcp_public_ip : PSK "$ipsec_psk"
EOF
ipsec_file=/tmp/ipsec.conf
cat <<EOF > $ipsec_file
config setup
        charondebug="all"
        uniqueids=yes
        strictcrlpolicy=no
conn google
  authby=secret
  leftid=$azure_public_ip
  leftsubnet=0.0.0.0/0
  right= $gcp_public_ip
  rightsubnet=0.0.0.0/0
  keyexchange=ikev2
  ikelifetime=28800s
  keylife=3600s
  keyingtries=3
  compress=no
  auto=start
  ike=aes256-sha1-modp1024
  esp=aes256-sha1
  mark=11
EOF
echo "Copying files to Azure VM..."
username=$(whoami)
scp $vpn_psk_file $azure_public_ip:/home/$username/ipsec.secrets
scp $ipsec_file $azure_public_ip:/home/$username/ipsec.conf
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo mv ./ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo systemctl restart ipsec"

# Google: IPsec config files
vpn_psk_file=/tmp/ipsec.secrets
cat <<EOF > $vpn_psk_file
$gcp_public_ip  $azure_public_ip : PSK "$ipsec_psk"
EOF
ipsec_file=/tmp/ipsec.conf
cat <<EOF > $ipsec_file
config setup
        charondebug="all"
        uniqueids=yes
        strictcrlpolicy=no
conn azure
  authby=secret
  leftid=$gcp_public_ip
  leftsubnet=0.0.0.0/0
  right= $azure_public_ip
  rightsubnet=0.0.0.0/0
  keyexchange=ikev2
  ikelifetime=28800s
  keylife=3600s
  keyingtries=3
  compress=no
  auto=start
  ike=aes256-sha1-modp1024
  esp=aes256-sha1
  mark=11
EOF
echo "Copying files to Google VM..."
username=$(whoami)
gcloud compute scp --zone=$zone $vpn_psk_file $gcp_vm_name:~/
gcloud compute scp --zone=$zone $ipsec_file $gcp_vm_name:~/
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo mv ./ipsec.* /etc/"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo systemctl restart ipsec"

# Configure BGP with Bird (Azure)
bird_config_file=/tmp/bird.conf
cat <<EOF > $bird_config_file
log syslog all;
router id $azure_private_ip;
protocol device {
        scan time 10;
}
protocol direct {
      disabled;
}
protocol kernel {
      preference 254;
      learn;
      merge paths on;
#      import filter {
#          if net ~ ${gcp_private_ip}/32 then accept;
#          else reject;
#      };
#      export filter {
#          if net ~ ${gcp_private_ip}/32 then reject;
#          else accept;
#      };
      import filter {reject;};
      export filter {reject;};
}
protocol static {
      import all;
      # Test route
      route 1.1.1.1/32 via $azure_default_gw;
}
protocol bgp google {
      description "VPN Gateway instance 0";
      multihop;
      local $azure_private_ip as $azure_asn;
      neighbor $gcp_private_ip as $gcp_asn;
          import filter {accept;};
          export filter {accept;};
}
EOF
echo "Copying BGP config file to Azure..."
username=$(whoami)
scp $bird_config_file "${azure_public_ip}:/home/${username}/bird.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo systemctl restart bird"

# Configure BGP with Bird (Google)
bird_config_file=/tmp/bird.conf
cat <<EOF > $bird_config_file
log syslog all;
router id $gcp_private_ip;
protocol device {
        scan time 10;
}
protocol direct {
      disabled;
}
protocol kernel {
      preference 254;
      learn;
      merge paths on;
#      import filter {
#          if net ~ ${azure_private_ip}/32 then accept;
#          else reject;
#      };
#      export filter {
#          if net ~ ${azure_private_ip}/32 then reject;
#          else accept;
#      };
      import filter {reject;};
      export filter {reject;};
}
protocol static {
      import all;
      # Test route
      route 2.2.2.2/32 via $gcp_default_gw;
}
protocol bgp azure {
      description "VPN Gateway instance 0";
      multihop;
      local $gcp_private_ip as $gcp_asn;
      neighbor $azure_private_ip as $azure_asn;
          import filter {accept;};
          export filter {accept;};
}
EOF
echo "Copying BGP config file to Google Cloud..."
gcloud compute scp --zone=$zone $bird_config_file $gcp_vm_name:~/
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo mv ./bird.conf /etc/bird/bird.conf"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo systemctl restart bird"

######################
# Modify VPC routing #
######################

# Variables
peer_name=gcpnva
gcp_router_ip0=10.0.2.250
gcp_router_ip1=10.0.2.251
ncc_hub_name=hub
ncc_spoke_name=router-spoke

# Enable connectivity API and create GCC
gcloud services enable networkconnectivity.googleapis.com
gcloud network-connectivity hubs create $ncc_hub_name --description="My Network Connectivity Center"
ncc_hub_uri="https://www.googleapis.com/networkconnectivity/$(gcloud network-connectivity hubs describe $ncc_hub_name --format=json | jq -r '.name')" && echo "$ncc_hub_uri"
nva_uri=$(gcloud compute instances describe "${gcp_vm_name}" --zone=$zone --format=json | jq -r '.selfLink') && echo $nva_uri
gcloud network-connectivity spokes linked-router-appliances create $ncc_spoke_name --hub "$ncc_hub_uri" --description="Ubuntu NVA" \
      --router-appliance=instance=$nva_uri,ip=$gcp_private_ip --region=$region
 
# Create router
gcloud compute routers create $gcp_router_name --project=$project_id --network=$gcp_vpc_name --asn=$gcp_router_asn --region=$region
gcloud compute routers add-interface $gcp_router_name --region=$region --subnetwork=$gcp_subnet_name --interface-name=${gcp_router_name}-0 --ip-address $gcp_router_ip0
gcloud compute routers add-bgp-peer $gcp_router_name --interface=${gcp_router_name}-0 --region=$region --peer-name=${peer_name}-0 --peer-ip-address=$gcp_private_ip --peer-asn="$gcp_asn"
gcloud compute routers add-interface $gcp_router_name --region=$region --subnetwork=$gcp_subnet_name --interface-name=${gcp_router_name}-1 --ip-address $gcp_router_ip1
gcloud compute routers add-bgp-peer $gcp_router_name --interface=${gcp_router_name}-1 --region=$region --peer-name=${peer_name}-1  --peer-ip-address=$gcp_private_ip --peer-asn="$gcp_asn"

# Configure BGP with Bird (Google)
bird_config_file=/tmp/bird.conf
cat <<EOF > $bird_config_file
log syslog all;
router id $gcp_private_ip;
protocol device {
        scan time 10;
}
protocol direct {
      disabled;
}
protocol kernel {
      preference 254;
      learn;
      merge paths on;
#      import filter {
#          if net ~ ${azure_private_ip}/32 then accept;
#          else reject;
#      };
#      export filter {
#          if net ~ ${azure_private_ip}/32 then reject;
#          else accept;
#      };
      import filter {reject;};
      export filter {reject;};
}
protocol static {
      import all;
      # Test route
      route 2.2.2.2/32 via $gcp_default_gw;
}
protocol bgp azure {
      description "Azure NVA";
      multihop;
      local $gcp_private_ip as $gcp_asn;
      neighbor $azure_private_ip as $azure_asn;
          import filter {accept;};
          export filter {accept;};
}
protocol bgp gcprouter0 {
      description "GCP Router interface 0";
      multihop;
      local $gcp_private_ip as $gcp_asn;
      neighbor $gcp_router_ip0 as $gcp_router_asn;
          import filter {accept;};
          export filter {accept;};
}
protocol bgp gcprouter1 {
      description "GCP Router interface 1";
      multihop;
      local $gcp_private_ip as $gcp_asn;
      neighbor $gcp_router_ip1 as $gcp_router_asn;
          import filter {accept;};
          export filter {accept;};
}
EOF
echo "Copying BGP config file to Google Cloud..."
gcloud compute scp --zone=$zone $bird_config_file $gcp_vm_name:~/
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo mv ./bird.conf /etc/bird/bird.conf"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo systemctl restart bird"


###############
# Diagnostics #
###############

# Azure
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "ip a"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "ifconfig vti0"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "ip -s tunnel show"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ip xfrm state"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "cat /proc/net/xfrm_stat"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "ip route"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "systemctl status ipsec"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ipsec statusall"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo cat /etc/ipsec.secrets"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo cat /etc/ipsec.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo grep install_routes /etc/strongswan.d/charon.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "ping -c 5 $gcp_private_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "systemctl status bird"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo birdc show status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo birdc show prot"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo birdc show prot all google"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo birdc show route"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo birdc show route all"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $azure_public_ip "sudo birdc show route export google"

# Google
gcloud compute ssh $gcp_vm_name --zone=$zone --command="ip a"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="ip route"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="systemctl status ipsec"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ipsec status"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo cat /etc/ipsec.secrets"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo cat /etc/ipsec.conf"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo grep install_routes /etc/strongswan.d/charon.conf"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo ipsec status"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="ping -c 5 $azure_private_ip"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="systemctl status bird"
gcloud compute ssh $gcp_vm_name --zone=$zone --command="sudo birdc show prot"

# VPC
gcloud compute networks list
gcloud compute routes list --filter=$gcp_vpc_name

#############
#  Cleanup  #
#############

# Delete GCP project
if [[ "$deploy_er" == "yes" ]]; then
    gcloud projects delete "$project_id"
    gcloud projects list
fi

# Delete Azure infrastructure
az group delete -n $rg -y --no-wait
