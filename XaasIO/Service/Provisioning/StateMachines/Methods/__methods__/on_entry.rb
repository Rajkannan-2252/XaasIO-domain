#
# Description: Method executed at the beginning of the state machine
#

$evm.log(:info, "Starting on_entry method for delete_powered_off_vms state machine")

# You can add initialization code here
# For example, setting variables in the state machine's root object

$evm.log(:info, "Completed on_entry method")
exit MIQ_OK
