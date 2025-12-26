class ManageIQ::Providers::Openstack::StorageManager::CinderManager::CloudVolumeSnapshot < ::CloudVolumeSnapshot
  include ManageIQ::Providers::Openstack::HelperMethods
  include SupportsFeatureMixin

  supports :create
  supports :update
  supports :delete
  supports :refresh_ems

  def provider_object(connection)
    connection.snapshots.get(ems_ref)
  end

  def with_provider_object
    super(connection_options)
  end

  def self.raw_create_snapshot(cloud_volume, options = {})
  raise ArgumentError, _("cloud_volume cannot be nil") if cloud_volume.nil?
  ext_management_system = cloud_volume.try(:ext_management_system)
  raise ArgumentError, _("ext_management_system cannot be nil") if ext_management_system.nil?

  cloud_tenant = cloud_volume.cloud_tenant
  snapshot_data = nil

  with_notification(:cloud_volume_snapshot_create,
                    :options => {
                      :snapshot_name => options[:name],
                      :volume_name   => cloud_volume.name,
                    }) do
    ext_management_system.with_provider_connection(connection_options(cloud_tenant)) do |service|
      snapshot_data = service.create_snapshot(
        cloud_volume.ems_ref,
        options[:name],
        options[:description],
        true
      ).body["snapshot"]
    end
  end

  snapshot = create(
    :name                  => snapshot_data["name"],
    :description           => snapshot_data["description"],
    :ems_ref               => snapshot_data["id"],
    :status                => snapshot_data["status"],
    :size                  => snapshot_data["size"]&.to_i&.gigabytes,  # Initial size if available
    :cloud_volume          => cloud_volume,
    :cloud_tenant          => cloud_tenant,
    :ext_management_system => ext_management_system,
  )

  # Queue aggressive refresh for this snapshot
  snapshot.queue_status_refresh

  snapshot
rescue => e
  parsed_error = parse_error_message_from_fog_response(e)
  _log.error("snapshot=[#{options[:name]}], error: #{parsed_error}")
  raise MiqException::MiqVolumeSnapshotCreateError, parsed_error, e.backtrace
end

# Add this new method
def queue_status_refresh(interval: 5, max_attempts: 24)
  # Refresh every 5 seconds for up to 2 minutes (24 attempts)
  max_attempts.times do |attempt|
    MiqQueue.put(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => "refresh_status_from_provider",
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => "ems_operations",
      :deliver_on  => Time.now + (interval * attempt).seconds
    )
  end
end

def refresh_status_from_provider
  with_provider_object do |snapshot|
    if snapshot
      old_status = self.status

      # Update ALL fields from provider, not just status
      update_attributes = {
        :status => snapshot.status
      }

      # Add size if available
      if snapshot.respond_to?(:size) && snapshot.size
        update_attributes[:size] = snapshot.size.to_i.gigabytes
      end

      # Add creation time if available and not already set
      if snapshot.respond_to?(:created_at) && snapshot.created_at && !self.creation_time
        update_attributes[:creation_time] = Time.parse(snapshot.created_at.to_s)
      end

      # Add description if changed
      if snapshot.respond_to?(:description) && snapshot.description && snapshot.description != self.description
        update_attributes[:description] = snapshot.description
      end

      # Update all attributes at once
      update!(update_attributes)

      # Stop polling if reached final state
      if status == "available" || status == "error"
        _log.info("Snapshot #{name} reached final status: #{status}, size: #{size ? size / 1.gigabyte : 'N/A'} GB")
       # Cancel remaining queued refreshes
        MiqQueue.where(
          class_name: self.class.name,
          instance_id: id,
          method_name: "refresh_status_from_provider",
          state: "ready"
        ).destroy_all
      end

      _log.info("Snapshot #{name} status: #{old_status} -> #{status}") if old_status != status
    end
  end
rescue => e
  _log.warn("Failed to refresh snapshot status: #{e.message}")
end

  def refresh_ems
    unless ext_management_system
      raise MiqException::MiqVolumeSnapshotUpdateError, "No provider connection available"
    end
    
    ext_management_system.refresh_snapshot(self)
  end

  def raw_update_snapshot(options = {})
    with_provider_object do |snapshot|
      if snapshot
        snapshot.update(options)
      else
        raise MiqException::MiqVolumeSnapshotUpdateError("snapshot does not exist")
      end
    end
  rescue => e
    parsed_error = parse_error_message_from_fog_response(e)

    _log.error("snapshot=[#{name}], error: #{parsed_error}")
    raise MiqException::MiqVolumeSnapshotUpdateError, parsed_error, e.backtrace
  end

  def raw_delete_snapshot(_options = {})
    with_notification(:cloud_volume_snapshot_delete,
                      :options => {
                        :subject       => self,
                        :volume_name   => cloud_volume.name,
                      }) do
      with_provider_object do |snapshot|
        if snapshot
          snapshot.destroy
        else
          _log.warn("snapshot=[#{name}] already deleted")
        end
      end
    end
  rescue => e
    parsed_error = parse_error_message_from_fog_response(e)

    _log.error("snapshot=[#{name}], error: #{parsed_error}")
    raise MiqException::MiqVolumeSnapshotDeleteError, parsed_error, e.backtrace
  end

  def self.connection_options(cloud_tenant = nil)
    connection_options = { :service => 'Volume' }
    connection_options[:tenant_name] = cloud_tenant.name if cloud_tenant
    connection_options
  end

  private

  def connection_options
    self.class.connection_options(cloud_tenant)
  end
end
