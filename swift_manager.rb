class ManageIQ::Providers::Openstack::StorageManager::CinderManager < ManageIQ::Providers::StorageManager
  include ManageIQ::Providers::StorageManager::BlockMixin
  include ManageIQ::Providers::Openstack::ManagerMixin

  supports :cinder_volume_types
  supports :volume_multiattachment
  supports :volume_resizing
  supports :volume_availability_zones
  supports :cloud_volume
  supports :cloud_volume_create

  supports :events do
    if parent_manager
      parent_manager.unsupported_reason(:events)
    else
      _('no parent_manager to ems')
    end
  end

  # Auth and endpoints delegations, editing of this type of manager must be disabled
  delegate :authentication_check,
           :authentication_status,
           :authentication_status_ok?,
           :authentications,
           :authentication_for_summary,
           :zone,
           :openstack_handle,
           :connect,
           :verify_credentials,
           :with_provider_connection,
           :address,
           :ip_address,
           :hostname,
           :default_endpoint,
           :endpoints,
           :cloud_tenants,
           :volume_availability_zones,
           :to        => :parent_manager,
           :allow_nil => true

  virtual_delegate :cloud_tenants, :to => :parent_manager, :allow_nil => true
  virtual_delegate :volume_availability_zones, :to => :parent_manager, :allow_nil => true

  # Callbacks to ensure name is persisted to database
  before_validation :sync_name_with_parent
  after_save :ensure_name_persisted

  class << self
    delegate :refresh_ems, :to => ManageIQ::Providers::Openstack::CloudManager
  end

  def self.default_blacklisted_event_names
    %w(
      scheduler.run_instance.start
      scheduler.run_instance.scheduled
      scheduler.run_instance.end
    )
  end

  def self.hostname_required?
    false
  end

  def self.ems_type
    @ems_type ||= "cinder".freeze
  end

  def self.description
    @description ||= "Cinder ".freeze
  end

  def description
    @description ||= "Cinder ".freeze
  end

  # Override name to return from database if present, otherwise compute from parent
  def name
    # Return persisted name if present
    return read_attribute(:name) if read_attribute(:name).present?
    
    # Otherwise compute from parent
    parent_manager.try(:name) ? "#{parent_manager.name} Cinder Manager" : nil
  end

  # Setter to allow persisting name
  def name=(value)
    write_attribute(:name, value)
  end

  def supported_auth_types
    %w(default amqp)
  end

  def self.event_monitor_class
    ManageIQ::Providers::Openstack::StorageManager::CinderManager::EventCatcher
  end

  def allow_targeted_refresh?
    true
  end

  def stop_event_monitor_queue_on_change
    if !self.new_record? && parent_manager && (authentications.detect{ |x| x.previous_changes.present? } ||
                                                    endpoints.detect{ |x| x.previous_changes.present? })
      _log.info("EMS: [#{name}], Credentials or endpoints have changed, stopping Event Monitor. It will be restarted by the WorkerMonitor.")
      stop_event_monitor_queue
    end
  end

  def self.display_name(number = 1)
    n_('Cinder Block Storage Manager (OpenStack)', 'Cinder Block Storage Managers (OpenStack)', number)
  end

  private

  # Sync name with parent before validation
  def sync_name_with_parent
    return unless parent_manager && parent_manager.name.present?
    
    expected_name = "#{parent_manager.name} Cinder Manager"
    write_attribute(:name, expected_name) if read_attribute(:name) != expected_name
  end

  # Ensure name is persisted after save
  def ensure_name_persisted
    return if read_attribute(:name).present?
    return unless parent_manager && parent_manager.name.present?
    
    expected_name = "#{parent_manager.name} Cinder Manager"
    update_column(:name, expected_name)
  end
end
