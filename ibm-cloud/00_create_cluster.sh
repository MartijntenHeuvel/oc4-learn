# to get available zones 
# ibmcloud oc zone ls --provider classic
export DataCenterZone=ams03
export ClusterName="democluster"

# Ensure cluster name is lower case and no _,as it makes some issues to s3
ClusterName=$(sed -e 's/\(.*\)/\L\1/' <<< "$ClusterName")
echo "ClusterName is ${ClusterName}"


ibmcloud login -a https://api.eu-de.bluemix.net -r eu-de -u rahmed@redhat.com -p xxxxxx -c 63cf37b8c3bb448cbf9b7507cc8ca57d -g benelux

export PrivateVlanId=$(ibmcloud sl vlan list -d $DataCenterZone --output json | jq '.[] | select(.networkSpace=="PRIVATE")' | jq ."id"| head -n1)
echo "private is ${PrivateVlanId}"

if [ "${PrivateVlanId}" == "" ]; then
  # Create VPC for deployment
  echo "Createing Private VPC"
  ibmcloud sl vlan create -t private -d $DataCenterZone -f
  export PrivateVlanId=$(ibmcloud sl vlan list -d $DataCenterZone --output json | jq '.[] | select(.networkSpace=="PRIVATE")' | jq ."id"| head -n1)
fi


export PublicVlanId=$(ibmcloud sl vlan list -d $DataCenterZone --output json | jq '.[] | select(.networkSpace=="PUBLIC")' | jq ."id"| head -n1)
echo "public is ${PublicVlanId}"

if [ "${PublicVlanId}" == "" ]; then
  # Create VPC for deployment
  echo "Createing Public VPC"
  ibmcloud sl vlan create -t public -d $DataCenterZone -f
  export PublicVlanId=$(ibmcloud sl vlan list -d $DataCenterZone --output json | jq '.[] | select(.networkSpace=="PUBLIC")' | jq ."id"| head -n1)
fi



if [[ -z "${PrivateVlanId}" ]] || [[ -z "${PublicVlanId}" ]]; then
  echo "can not create cluster as vlan creation failed" >&2
  exit 1
fi


ibmcloud oc cluster create classic --name $ClusterName --location $DataCenterZone --version 4.3_openshift --flavor b3c.4x16.encrypted  --workers 3 --public-vlan $PublicVlanId --private-vlan $PrivateVlanId --public-service-endpoint

while [ "$(ibmcloud ks cluster ls --json | jq --arg ClusterName $ClusterName '.[] | select(.name==$ClusterName)'|  jq .'state')" != \""normal\"" ] ; do
  echo "not yet deployed, sleeping..."
  sleep 90
done


# To Get the object storage service name
# ibmcloud catalog service-marketplace | grep "storage"

# To Get the object storage service plan
# ibmcloud catalog service cloud-object-storage


# Creating the IBM object storage service
ibmcloud resource service-instance-create "$ClusterName"-cos cloud-object-storage standard global

export COSServiceId=$(ibmcloud resource service-instance "$ClusterName"-cos --output json | jq '.[]'|  jq .'crn')

COSServiceId=$(sed -e 's/^"//' -e 's/"$//' <<<"$COSServiceId")


echo "COSServiceId=$COSServiceId"
# Creating credentials for IBM object storage service

ibmcloud resource service-key-create "$ClusterName"-creds Writer --instance-name "$ClusterName"-cos --parameters '{"HMAC":true}'

export CredServiceKeyId=$(ibmcloud resource service-key "$ClusterName"-creds --output json | jq '.[]'|  jq .'crn')
export AccessKeyId=$(ibmcloud resource service-key "$ClusterName"-creds --output json | jq '.[]'|  jq .'credentials.cos_hmac_keys.access_key_id')
export SecretAccessKey=$(ibmcloud resource service-key "$ClusterName"-creds --output json | jq '.[]'|  jq .'credentials.cos_hmac_keys.secret_access_key')

AccessKeyId=$(sed -e 's/^"//' -e 's/"$//' <<<"$AccessKeyId")
SecretAccessKey=$(sed -e 's/^"//' -e 's/"$//' <<<"$SecretAccessKey")


export BucketName="$ClusterName"-bucket
echo "BucketName=$BucketName"

ibmcloud cos config auth --method IAM
ibmcloud cos create-bucket --bucket "$BucketName" --ibm-service-instance-id $COSServiceId --region eu-de

#Switch kubeconfig context
ibmcloud oc cluster config --cluster $ClusterName --admin

oc create secret generic image-registry-private-configuration-user --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="$AccessKeyId" --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$SecretAccessKey" --namespace openshift-image-registry

#TODO: I want to use encrypt, keyID to integarte with IBM KMS and encrypt images .. WIP

oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"storage":{"pvc":null,"s3":{"bucket":"'$BucketName'","region":"eu-de","regionEndpoint":"s3.direct.eu-de.cloud-object-storage.appdomain.cloud"}}}}'

#ibmcloud ks kms

#aws --endpoint-url=https://s3.ams.eu.cloud-object-storage.appdomain.cloud s3 ls


exit;
