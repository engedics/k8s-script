#!/bin/bash
#exit on error
set -e

#requirements
#user added to sudoers with nopasswd
#node ALL=(ALL) NOPASSWD:ALL

#SSH setup on control and node
#ssh-keygen
#ssh-copy-id node@<node>

#optional autocompletion
#apt-get install bash-completion
#echo 'source <(kubectl completion bash)' >>~/.bashrc

#getting arguments
echo "===>>> Setting arguments"
nodeuser=$1
node=$2
controluser=$3
control=$4
master=$5

echo "===>>> Checking dependencies"
if ! [ -x "$(command -v jq)" ]; then
	sudo apt-get install -y jq
fi

if ! [ -x "$(command -v iperf3)" ]; then
	sudo apt-get install -y iperf3
fi

if ! [ -x "$(command -v /usr/lib/go-1.8/bin/go)" ]; then
	sudo apt-get install -y golang-1.8
fi
if ! [ -x "$(command -v ~/go/bin/fortio)" ]; then
	/usr/lib/go-1.8/bin/go get fortio.org/fortio
fi

ssh $nodeuser@$node 'bash -s' <<'ENDSSH'
if ! [ -x "$(command -v iperf3)" ]; then
	sudo apt-get install -y iperf3
fi

if ! [ -x "$(command -v /usr/lib/go-1.8/bin/go)" ]; then
	sudo apt-get install -y golang-1.8
fi
if ! [ -x "$(command -v ~/go/bin/fortio)" ]; then
	/usr/lib/go-1.8/bin/go get fortio.org/fortio
fi
ENDSSH

ssh $controluser@$control 'bash -s' <<'ENDSSH'
if ! [ -x "$(command -v iperf3)" ]; then
	sudo apt-get install -y iperf3
fi

if ! [ -x "$(command -v /usr/lib/go-1.8/bin/go)" ]; then
	sudo apt-get install -y golang-1.8
fi
if ! [ -x "$(command -v ~/go/bin/fortio)" ]; then
	/usr/lib/go-1.8/bin/go get fortio.org/fortio
fi
ENDSSH

#create folders for json storing
mkdir fortio_json || true
mkdir iperf_json || true

#perform physical network test to master
echo "===>>> Physical network: master <-> control" | tee -a results.txt
sleep 2
iperf3 -s -D -1
ssh $controluser@$control "iperf3 -c $master -J -t 30" > iperf_json/phy_master.json
cat iperf_json/phy_master.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
~/go/bin/fortio server &>/dev/null &
ssh $controluser@$control "~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$master:8080/echo" > fortio_json/phy_master.json
 
#perform physical network test to node
echo "===>>> Physical network: node <-> control" | tee -a results.txt
sleep 2
ssh $nodeuser@$node "iperf3 -s -D -1"
ssh $controluser@$control "iperf3 -c $node -J -t 30" > iperf_json/phy_node.json
cat iperf_json/phy_node.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
ssh $nodeuser@$node "~/go/bin/fortio server &>/dev/null &"
ssh $controluser@$control "~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$node:8080/echo" > fortio_json/phy_node.json

#perform physical network test between master and node
echo "===>>> Physical network: master <-> node" | tee -a results.txt
sleep 2
ssh $nodeuser@$node "iperf3 -s -D -1"
iperf3 -c $node -J -t 30 > iperf_json/phy_masternode.json
cat iperf_json/phy_masternode.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
ssh $nodeuser@$node "~/go/bin/fortio server &>/dev/null &"
~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$node:8080/echo > fortio_json/phy_masternode.json

for cni in Flannel Weavenet Calico
do
	#
	#SETTING UP THE CLUSTER
	#
	subnet=''
	case $cni in
			Flannel)
					subnet='10.244.0.0/16'
					;;
			Weavenet)
					subnet='10.32.0.0/12'
					;;
			Calico)
					subnet='10.245.0.0/16'
					;;
	esac
	echo "===>>> Setting up the cluster"
	sudo swapoff -a
	ssh $nodeuser@$node "sudo swapoff -a"
	sudo kubeadm init --pod-network-cidr=$subnet
	echo "===>>> Setting kubeconfig"
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
	#joining the node
	echo "===>>> Joining the node to the cluster"
	joincmd=$(sudo kubeadm token create --print-join-command)
	ssh $nodeuser@$node "sudo $joincmd"

	#applying CNI script
	case $cni in
			Flannel)
					echo "===>>> Applying Flannel"
					kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
					;;
			Weavenet)
					echo "===>>> Applying Weavenet"
					kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
					;;
			Calico)
					echo "===>>> Applying Calico"
					kubectl apply -f https://raw.githubusercontent.com/engedics/k8s-script/master/calico.yml
					;;
	esac

	#wait for CNI to finish and nodes to get ready
	echo "===>>> Waiting for the nodes to get ready"
	ready0=$(kubectl get nodes -o json | jq '.items[0].status.conditions[] | select(.type == "Ready") | .status')
	ready1=$(kubectl get nodes -o json | jq '.items[1].status.conditions[] | select(.type == "Ready") | .status')
	while [ $ready0 != "\"True\"" ] && [ $ready1 != "\"True\"" ]
	do
		echo "Waiting..."
		sleep 5
		ready0=$(kubectl get nodes -o json | jq '.items[0].status.conditions[] | select(.type == "Ready") | .status')
		ready1=$(kubectl get nodes -o json | jq '.items[1].status.conditions[] | select(.type == "Ready") | .status')
	done

	#
	#CREATING TEST PODS
	#
	#create a pod on each node
	echo "===>>> Creating iperf3 pods"
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/iperf3-master.yml
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/iperf3-node.yml

	#create a service for each
	echo "===>>> Creating iperf3 services"
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/iperf3-svc-master.yml
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/iperf3-svc-node.yml
	
	#create a pod on each node
	echo "===>>> Creating fortio pods"
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/fortio-master.yml
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/fortio-node.yml

	#create a service for each
	echo "===>>> Creating fortio services"
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/fortio-svc-master.yml
	kubectl create -f https://raw.githubusercontent.com/engedics/k8s-script/master/fortio-svc-node.yml

	#wait for pod readiness
	echo "===>>> Waiting for the pods to get ready"
	ready0=$(kubectl get pods -o json | jq '.items[0].status.conditions[] | select(.type == "Ready") | .status')
	ready1=$(kubectl get pods -o json | jq '.items[1].status.conditions[] | select(.type == "Ready") | .status')
	ready2=$(kubectl get pods -o json | jq '.items[2].status.conditions[] | select(.type == "Ready") | .status')
	ready3=$(kubectl get pods -o json | jq '.items[3].status.conditions[] | select(.type == "Ready") | .status')
	while [ $ready0 != "\"True\"" ] && [ $ready1 != "\"True\"" ] && [ $ready2 != "\"True\"" ] && [ $ready3 != "\"True\"" ]
	do
		echo "Waiting..."
		sleep 5
		ready0=$(kubectl get pods -o json | jq '.items[0].status.conditions[] | select(.type == "Ready") | .status')
		ready1=$(kubectl get pods -o json | jq '.items[1].status.conditions[] | select(.type == "Ready") | .status')
		ready2=$(kubectl get pods -o json | jq '.items[2].status.conditions[] | select(.type == "Ready") | .status')
		ready3=$(kubectl get pods -o json | jq '.items[3].status.conditions[] | select(.type == "Ready") | .status')
	done

	#hostport tests are only needed once
	if [ $cni == "Flannel" ]
	then
		#perform hostport test to master
		echo "===>>> Hostport: control <-> master" | tee -a results.txt
		sleep 2
		ssh $controluser@$control "iperf3 -c $master -p 5202 -J -t 30" > iperf_json/hst_master.json
		cat iperf_json/hst_master.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
		ssh $controluser@$control "~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$master:8081/echo" > fortio_json/hst_master.json

		#perform hostport test to node
		echo "===>>> Hostport: control <-> node" | tee -a results.txt
		sleep 2
		ssh $controluser@$control "iperf3 -c $node -p 5202 -J -t 30" > iperf_json/hst_node.json
		cat iperf_json/hst_node.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
		ssh $controluser@$control "~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$node:8081/echo" > fortio_json/hst_node.json
	fi
	
	#perform service test to master pod
	echo "===>>> $cni: control <-> master" | tee -a results.txt
	sleep 2
	ssh $controluser@$control "iperf3 -c $master -p 30000 -J -t 30" > iperf_json/svc_master_$cni.json
	cat iperf_json/svc_master_$cni.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
	ssh $controluser@$control "~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$master:30080/echo" > fortio_json/svc_master_$cni.json

	#perform service test to node pod
	echo "===>>> $cni: control <-> node" | tee -a results.txt
	sleep 2
	ssh $controluser@$control "iperf3 -c $master -p 30001 -J -t 30" > iperf_json/svc_node_$cni.json
	cat iperf_json/svc_node_$cni.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
	ssh $controluser@$control "~/go/bin/fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$master:30180/echo" > fortio_json/svc_node_$cni.json
	
	#perform service test between master and node pod
	echo "===>>> $cni: master <-> node" | tee -a results.txt
	sleep 2
	kubectl exec -it iperf3-master -- iperf3 -c $master -p 30001 -J -t 30 > iperf_json/svc_inter_$cni.json
	cat iperf_json/svc_inter_$cni.json | jq '.end.sum_sent.bits_per_second' | tee -a results.txt
	kubectl exec -it fortio-node -- fortio load -json - -quiet -c 32 -qps 0 -t 30s -r 0.0001 http://$master:30080/echo > fortio_json/svc_inter_$cni.json 
	sed -i 1,10d fortio_json/svc_inter_$cni.json 
	sed -i '$d' fortio_json/svc_inter_$cni.json 

	#removing pods and services
	echo "===>>> Removing pods and services"
	kubectl delete pod iperf3-master
	kubectl delete pod iperf3-node
	kubectl delete service iperf3-svc-master
	kubectl delete service iperf3-svc-node
	kubectl delete pod fortio-master
	kubectl delete pod fortio-node
	kubectl delete service fortio-svc-master
	kubectl delete service fortio-svc-node

	#tear down cluster
	echo "===>>> Tearing down the cluster"
	kubectl drain node --delete-local-data --force --ignore-daemonsets
	kubectl delete node node
	ssh $nodeuser@$node "sudo kubeadm reset -f"
	ssh $nodeuser@$node "sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X"
	kubectl drain master --delete-local-data --force --ignore-daemonsets
	kubectl delete node master
	sudo kubeadm reset -f
	sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
	rm $HOME/.kube/config
done
