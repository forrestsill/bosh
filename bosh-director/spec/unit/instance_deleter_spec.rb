require 'spec_helper'

module Bosh::Director
  describe InstanceDeleter do
    before { allow(App).to receive_message_chain(:instance, :blobstores, :blobstore).and_return(blobstore) }
    let(:blobstore) { instance_double('Bosh::Blobstore::Client') }
    let(:domain) { Models::Dns::Domain.make(name: 'bosh') }
    let(:skip_drain_decider) { Bosh::Director::DeploymentPlan::AlwaysSkipDrain.new }
    let(:cloud) { instance_double('Bosh::Cloud') }
    before { allow(Config).to receive(:cloud).and_return(cloud) }

    let(:ip_provider) { instance_double(DeploymentPlan::IpProviderV2) }
    let(:dns_manager) { instance_double(DnsManager, delete_dns_for_instance: nil) }
    let(:deleter) { InstanceDeleter.new(ip_provider, skip_drain_decider, dns_manager) }

    describe '#delete_instances' do
      let(:event_log_stage) { instance_double('Bosh::Director::EventLog::Stage') }
      let(:instances_to_delete) do
        instances = []
        5.times { instances << instance_double(DeploymentPlan::Instance) }
        instances
      end

      before do
        allow(event_log_stage).to receive(:advance_and_track).and_yield
      end

      let(:vm) do
        vm = DeploymentPlan::Vm.new
        vm.model = Models::Vm.make(cid: 'fake-vm-cid')
        vm
      end
      let(:network) { instance_double(DeploymentPlan::ManualNetwork, name: 'manual-network') }
      let(:reservation) do
        reservation = DesiredNetworkReservation.new(instance, network, '192.168.1.2', :dynamic)
        reservation.mark_reserved

        reservation
      end

      let(:deployment_model) { Models::Deployment.make(name: 'deployment-name') }
      let(:instance) do
        deployment_plan = instance_double(DeploymentPlan::Planner, ip_provider: ip_provider, model: deployment_model)
        job = instance_double(DeploymentPlan::Job, name: 'fake-job-name', deployment: deployment_plan)

        az = DeploymentPlan::AvailabilityZone.new('az', {})
        instance = DeploymentPlan::Instance.new(job, 5, {}, deployment_plan, 'started', az, true, logger)
        instance.bind_existing_instance_model(Models::Instance.make(vm: vm.model, deployment: deployment_model, uuid: 'uuid-1'))

        instance
      end

      let(:stopper) { instance_double(Stopper) }
      before do
        instance.add_network_reservation(reservation)

        allow(Stopper).to receive(:new).with(
            instance_of(DeploymentPlan::InstancePlan),
            'stopped',
            true,
            Config,
            logger
          ).and_return(stopper)
      end

      let(:job_templates_cleaner) do
        job_templates_cleaner = instance_double('Bosh::Director::RenderedJobTemplatesCleaner')
        allow(RenderedJobTemplatesCleaner).to receive(:new).with(instance.model, blobstore).and_return(job_templates_cleaner)
        job_templates_cleaner
      end

      let(:persistent_disks) do
        disk = Models::PersistentDisk.make(disk_cid: 'fake-disk-cid-1')
        Models::Snapshot.make(persistent_disk: disk)
        [Models::PersistentDisk.make(disk_cid: 'instance-disk-cid'), disk]
      end

      before do
        allow(Config).to receive(:dns_domain_name).and_return(domain.name)
        persistent_disks.each { |disk| instance.model.persistent_disks << disk }
      end

      it 'should delete the instances with the config max threads option' do
        allow(Config).to receive(:max_threads).and_return(5)
        pool = double('pool')
        allow(ThreadPool).to receive(:new).with(max_threads: 5).and_return(pool)
        allow(pool).to receive(:wrap).and_yield(pool)
        allow(pool).to receive(:process).and_yield

        5.times do |index|
          expect(deleter).to receive(:delete_instance).with(
              instances_to_delete[index],
              event_log_stage
            )
        end
        deleter.delete_instances(instances_to_delete, event_log_stage)
      end

      it 'should delete the instances with the respected max threads option' do
        pool = double('pool')
        allow(ThreadPool).to receive(:new).with(max_threads: 2).and_return(pool)
        allow(pool).to receive(:wrap).and_yield(pool)
        allow(pool).to receive(:process).and_yield

        5.times do |index|
          expect(deleter).to receive(:delete_instance).with(
              instances_to_delete[index], event_log_stage)
        end
        deleter.delete_instances(instances_to_delete, event_log_stage, max_threads: 2)
      end

      it 'drains, deletes snapshots, dns records, persistent disk, releases old reservations' do
        expect(stopper).to receive(:stop)
        expect(deleter).to receive(:delete_snapshots).with(instance.model)
        expect(deleter).to receive(:delete_persistent_disks).with(persistent_disks)
        expect(dns_manager).to receive(:delete_dns_for_instance).with(instance.model)
        expect(cloud).to receive(:delete_vm).with(vm.model.cid)
        expect(ip_provider).to receive(:release).with(reservation)

        expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')

        job_templates_cleaner = instance_double('Bosh::Director::RenderedJobTemplatesCleaner')
        allow(RenderedJobTemplatesCleaner).to receive(:new).with(instance.model, blobstore).and_return(job_templates_cleaner)
        expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

        deleter.delete_instances([instance], event_log_stage)

        expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
      end

      context 'when force option is passed in' do
        let(:deleter) { InstanceDeleter.new(ip_provider, skip_drain_decider, dns_manager, force: true) }

        context 'when stopping fails' do
          before do
            allow(stopper).to receive(:stop).and_raise(RpcTimeout)
          end

          it 'deletes snapshots, persistent disk, releases old reservations' do
            expect(deleter).to receive(:delete_snapshots)
            expect(deleter).to receive(:delete_persistent_disks)
            expect(dns_manager).to receive(:delete_dns_for_instance).with(instance.model)
            expect(cloud).to receive(:delete_vm).with(vm.model.cid)
            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')

            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            deleter.delete_instances([instance], event_log_stage)

            expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
          end
        end

        context 'when deleting vm fails' do
          before do
            allow(cloud).to receive(:delete_vm).and_raise(
                Bosh::Clouds::CloudError.new('Failed to create VM')
              )
          end

          it 'drains, deletes snapshots, persistent disk, releases old reservations' do
            expect(stopper).to receive(:stop)
            expect(deleter).to receive(:delete_snapshots)
            expect(deleter).to receive(:delete_persistent_disks)
            expect(dns_manager).to receive(:delete_dns_for_instance).with(instance.model)
            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')

            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            deleter.delete_instances([instance], event_log_stage)

            expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
          end
        end

        context 'when deleting snapshots fails' do
          before do
            allow(Bosh::Director::Api::SnapshotManager).to receive(:delete_snapshots).and_raise(
                Bosh::Clouds::CloudError.new('Failed to delete snapshots')
              )
          end

          it 'drains, deletes vm, persistent disk, releases old reservations' do
            expect(stopper).to receive(:stop)
            expect(cloud).to receive(:delete_vm).with(vm.model.cid)
            expect(deleter).to receive(:delete_persistent_disks)
            expect(dns_manager).to receive(:delete_dns_for_instance).with(instance.model)
            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')

            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            deleter.delete_instances([instance], event_log_stage)

            expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
          end
        end

        context 'when deleting disks fails' do
          before do
            allow(cloud).to receive(:delete_disk).and_raise(
                Bosh::Clouds::CloudError.new('Failed to delete disk')
              )
          end

          it 'drains, deletes vm, snapshots, releases old reservations' do
            expect(stopper).to receive(:stop)
            expect(cloud).to receive(:delete_vm).with(vm.model.cid)
            expect(Bosh::Director::Api::SnapshotManager).to receive(:delete_snapshots)
            expect(dns_manager).to receive(:delete_dns_for_instance).with(instance.model)
            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')

            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            deleter.delete_instances([instance], event_log_stage)

            expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
          end
        end

        context 'when deleting dns fails' do
          before do
            allow(dns_manager).to receive(:delete_dns_for_instance).and_raise('failed')
          end

          it 'drains, deletes vm, snapshots, disks, releases old reservations' do
            expect(stopper).to receive(:stop)
            expect(cloud).to receive(:delete_vm).with(vm.model.cid)
            expect(Bosh::Director::Api::SnapshotManager).to receive(:delete_snapshots)
            expect(cloud).to receive(:delete_disk).exactly(2).times
            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')

            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            deleter.delete_instances([instance], event_log_stage)

            expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
          end
        end

        context 'when cleaning templates fails' do
          before do
            allow(job_templates_cleaner).to receive(:clean_all).and_raise('failed')
          end

          it 'drains, deletes vm, snapshots, disks, releases old reservations' do
            expect(stopper).to receive(:stop)
            expect(cloud).to receive(:delete_vm).with(vm.model.cid)
            expect(Bosh::Director::Api::SnapshotManager).to receive(:delete_snapshots)
            expect(cloud).to receive(:delete_disk).exactly(2).times
            expect(ip_provider).to receive(:release).with(reservation)

            expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/5')
            expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

            deleter.delete_instances([instance], event_log_stage)

            expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
          end
        end
      end

      context 'when keep_snapshots_in_cloud is passed in' do
        let(:deleter) { InstanceDeleter.new(ip_provider, skip_drain_decider, dns_manager, keep_snapshots_in_the_cloud: true) }

        it 'deletes snapshots from DB keeping snapshots in cloud' do
          expect(stopper).to receive(:stop)
          expect(cloud).to receive(:delete_vm).with(vm.model.cid)
          expect(cloud).to receive(:delete_disk).exactly(2).times
          expect(dns_manager).to receive(:delete_dns_for_instance).with(instance.model)
          expect(ip_provider).to receive(:release).with(reservation)

          expect(cloud).to_not receive(:delete_snapshot)

          expect {
            deleter.delete_instances([instance], event_log_stage)
          }.to change { Bosh::Director::Models::Snapshot.count }.from(1).to(0)
        end
      end
    end

    describe :delete_persistent_disks do
      it 'should delete the persistent disks' do
        persistent_disks = [Models::PersistentDisk.make(active: true), Models::PersistentDisk.make(active: false)]
        persistent_disks.each { |disk| expect(cloud).to receive(:delete_disk).with(disk.disk_cid) }
        deleter.send(:delete_persistent_disks, persistent_disks)
        persistent_disks.each { |disk| expect(Models::PersistentDisk[disk.id]).to eq(nil) }
      end

      it 'should ignore errors to inactive persistent disks' do
        disk = Models::PersistentDisk.make(active: false)
        expect(cloud).to receive(:delete_disk).with(disk.disk_cid).and_raise(Bosh::Clouds::DiskNotFound.new(true))
        deleter.send(:delete_persistent_disks, [disk])
      end

      it 'should not ignore errors to active persistent disks' do
        disk = Models::PersistentDisk.make(active: true)
        expect(cloud).to receive(:delete_disk).with(disk.disk_cid).and_raise(Bosh::Clouds::DiskNotFound.new(true))
        expect { deleter.send(:delete_persistent_disks, [disk]) }.to raise_error(Bosh::Clouds::DiskNotFound)
      end
    end
  end
end
