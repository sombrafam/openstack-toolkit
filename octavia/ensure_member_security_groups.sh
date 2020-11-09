#!/bin/bash -eu
#
# Scans all Octavia loadbalancers, checks that all member ports' have a security
# group rule containing a rule that opens the port being loadbalanced.
#
SCRATCH_AREA=`mktemp -d`
LOADBALANCER=${1:-}

cleanup ()
{
    rm -rf $SCRATCH_AREA
}

trap cleanup KILL INT EXIT

if [ -z "${OS_AUTH_URL:-}" ]; then
    read -p "Path to credentials file: " openrc_path
    source $openrc_path
fi

mkdir -p $SCRATCH_AREA/results

echo -n "INFO: pre-fetching information..."

# Get all ports
echo -n "[ports]"
openstack port list -c ID -c fixed_ips -f value > $SCRATCH_AREA/port_list &

# Get all LBs and allow single loadbalancer override
echo -n "[loadbalancers]"
if [ -n "$LOADBALANCER" ]; then
    echo "$LOADBALANCER" > $SCRATCH_AREA/loadbalancer_list
else
    openstack loadbalancer list -c id -f value > $SCRATCH_AREA/loadbalancer_list &
fi
wait

# Extract port info
while read -r port_info; do
    uuid=${port_info%% *}
    mkdir -p $SCRATCH_AREA/ports/$uuid
    # note: format of this field changes across releases so this may need updating
    address=`echo ${port_info#* }| \
                 sed -rn -e "s/.+ip_address='([[:digit:]\.]+)',\s+.+/\1/" \
                         -e "s/.+ip_address':\s+'([[:digit:]\.]+)'}.+/\1/p"`
    echo $address > $SCRATCH_AREA/ports/$uuid/address
done < $SCRATCH_AREA/port_list

# Get pools, listeners and members
echo -n "[pools+members+listeners]"
while read -r lb; do
    mkdir -p $SCRATCH_AREA/$lb/pools
    for pool in `openstack loadbalancer pool list -c id -f value --loadbalancer $lb`; do
        mkdir -p $SCRATCH_AREA/$lb/pools/$pool
    done &
    wait

    for pool in `ls $SCRATCH_AREA/$lb/pools`; do
        mkdir -p $SCRATCH_AREA/$lb/listeners
        for listener in `openstack loadbalancer listener list| awk "\\$4==\"$pool\" {print \\$2}"`; do
            mkdir -p $SCRATCH_AREA/$lb/listeners/$listener
            readarray -t listener_info<<<"`openstack loadbalancer listener show $listener -f value -c protocol -c protocol_port`"
            echo "${listener_info[0]}" > $SCRATCH_AREA/$lb/listeners/$listener/protocol
            echo "${listener_info[1]}" > $SCRATCH_AREA/$lb/listeners/$listener/port
        done &
        for member in `openstack loadbalancer member list -c id -f value $pool`; do
            mkdir -p $SCRATCH_AREA/$lb/pools/$pool/members/$member
            openstack loadbalancer member show -c address -f value $pool $member > $SCRATCH_AREA/$lb/pools/$pool/members/$member/address
        done &
        wait
    done &
done < $SCRATCH_AREA/loadbalancer_list
wait

echo ""

get_security_group ()
{
    local sg=$1
    mkdir -p $SCRATCH_AREA/security_groups/$sg/rules
    for rule in `openstack security group rule list $sg -c ID -f value`; do
        openstack security group rule show $rule > $SCRATCH_AREA/security_groups/$sg/rules/$rule &
    done
    wait
}

# Run checks
echo "INFO: checking loadbalancers '`cat $SCRATCH_AREA/loadbalancer_list| tr -s '\n' ' '| sed -r 's/\s+$//g'`'"
while read -r lb; do
    (
    mkdir -p $SCRATCH_AREA/results/$lb
    mkdir -p $SCRATCH_AREA/security_groups
    for pool in `ls $SCRATCH_AREA/$lb/pools`; do
        for listener in `ls $SCRATCH_AREA/$lb/listeners`; do
            listener_port=`cat $SCRATCH_AREA/$lb/listeners/$listener/port`
            error_idx=0
            for member in `ls $SCRATCH_AREA/$lb/pools/$pool/members`; do
                address=`cat $SCRATCH_AREA/$lb/pools/$pool/members/$member/address`
                path=`egrep -lr "$address$" $SCRATCH_AREA/ports`
                port=$(basename `dirname $path`)
                for sg in `openstack port show -c security_group_ids -f value $port| egrep -o "[[:alnum:]\-]+"`; do
                    sg_path=$SCRATCH_AREA/security_groups/$sg
                    [ -d $sg_path ] || get_security_group $sg
                    found=false
                    for rule in `find $sg_path/rules/ -type f`; do
                        # THIS IS THE ACTUAL CHECK - ADD MORE AS NEEDED #
                        max_actual=`awk "\\$2==\"port_range_min\" {print \\$4}" $rule`
                        min_actual=`awk "\\$2==\"port_range_max\" {print \\$4}" $rule`
                        [[ "${min_actual}:${max_actual}" == "${listener_port}:${listener_port}" ]] || continue
                        direction=`awk "\\$2==\"direction\" {print \\$4}" $rule`
                        [[ "$direction" == "ingress" ]] || continue
                        found=true
                    done
                    if ! $found; then
                        error_path=$SCRATCH_AREA/results/$lb/errors/$error_idx
                        mkdir -p $error_path
                        echo "$listener_port" > $error_path/protocol_port
                        echo $member > $error_path/member
                        echo $port > $error_path/backend_vm_port
                        echo $sg > $error_path/security_group
                        for entry in `ls $error_path`; do
                            echo " - $entry: `cat $error_path/$entry`" >> $error_path/details
                        done
                        ((error_idx+=1))
                    fi
                done
            done
        done
    done > $SCRATCH_AREA/results/$lb/all
    ) &
done < $SCRATCH_AREA/loadbalancer_list
wait

for errors in `find $SCRATCH_AREA/results -name errors`; do
    lb=$(basename `dirname $errors`)
    for error in `ls $errors`; do
        port=`cat $errors/$error/protocol_port`
        echo -e "\nWARNING: loadbalancer $lb has member(s) with security groups that don't have required ports open: $port"
        echo "Details:"
        cat $errors/$error/details
    done
done
ls $SCRATCH_AREA/results/*/errors &>/dev/null && echo ""

echo "Done."
