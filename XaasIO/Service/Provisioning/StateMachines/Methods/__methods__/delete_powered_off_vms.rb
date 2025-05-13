#
# Description: Find and delete powered off VMs based on criteria
#

$evm.log(:info, "Starting delete_powered_off_vms method")

# Find VMs that are powered off
vms = $evm.vmdb('vm').find_all { |vm| vm.power_state == 'off' }
$evm.log(:info, "Found #{vms.length} powered off VMs")

# Process each VM
vms.each do |vm|
  # Add your criteria here
  # Example: Only delete VMs that have been off for more than 7 days
  if vm.power_state == 'off'
    last_power_state_change = vm.last_power_state_change
    if last_power_state_change && (Time.now.utc - last_power_state_change) > 7.days.to_i
      $evm.log(:info, "Deleting VM: #{vm.name}, powered off since #{last_power_state_change}")
      # Uncomment the line below to actually delete the VM
      # vm.remove_from_vmdb
    end
  end
end

$evm.log(:info, "Completed delete_powered_off_vms method")
exit MIQ_OK
