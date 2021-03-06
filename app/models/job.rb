require 'erubis'
require 'tempfile'
require 'open3'

class Job < ActiveRecord::Base

  validates_presence_of :job_group_id
  belongs_to :job_group
  belongs_to :config_template
  after_initialize :handle_after_init
  after_create :handle_after_create
  after_save :handle_after_save

  def handle_after_init
    if new_record? then
      self.status = "Pending"
    end
  end

  def handle_after_create
    AsyncExec.run_job(Job, self.id)
  end

  def handle_after_save
    self.job_group.update_attributes(
        :status => self.status
    )
  end

  @queue=:vpc

  def self.perform(id, script_text=nil)
    job = Job.find(id)
    job.update_attribute(:status, "Running")

    if script_text.nil?
        template = File.read(File.join(Rails.root, "app", "models", "vpc_runner.sh.erb"))
        eruby = Erubis::Eruby.new(template)
        script_text=eruby.result
    end
    script_file=Tempfile.new('smokestack')
    script_file.write(script_text)
    script_file.flush

	#chef_installer.yml
	chef_template = File.read(File.join(Rails.root, "app", "models", "chef_installer.yml.erb"))
	eruby = Erubis::Eruby.new(chef_template)
	chef_installer_text=eruby.result(:job => job)
    chef_installer_file=Tempfile.new('smokestack_chef')
    chef_installer_file.write(chef_installer_text)
    chef_installer_file.flush

	#nodes.json
    nodes_json_file=Tempfile.new('smokestack_nodes_json')
    nodes_json_file.write(job.config_template.nodes_json)
    nodes_json_file.flush

	#server_group.json
    server_group_json_file=Tempfile.new('smokestack_server_group_json')
    server_group_json_file.write(job.config_template.server_group_json)
    server_group_json_file.flush

    nova_builder=job.job_group.smoke_test.nova_package_builder
    glance_builder=job.job_group.smoke_test.glance_package_builder

    args = ["bash", script_file.path, nova_builder.url, nova_builder.merge_trunk.to_s, glance_builder.url, glance_builder.merge_trunk.to_s, chef_installer_file.path, nodes_json_file.path, server_group_json_file.path]

    Open3.popen3(*args) do |stdin, stdout, stderr, wait_thr|
        job.stdout=stdout.readlines.join.chomp
        job.stderr=stderr.readlines.join.chomp
        job.nova_revision=Job.parse_nova_revision(job.stdout)
        job.glance_revision=Job.parse_glance_revision(job.stdout)
        job.msg=Job.parse_last_message(job.stdout)
        job.save
        retval = wait_thr.value
        if retval.success? 
            job.update_attribute(:status, "Success")
            return true
        else
            job.update_attribute(:status, "Failed")
            return false
        end

    end
    script_file.close

  end

  def self.parse_nova_revision(stdout)
    stdout.each_line do |line|
      if line =~ /^NOVA_REVISION/ then
        return line.sub(/^NOVA_REVISION=/, "").chomp
      end
    end
    return ""
  end

  def self.parse_glance_revision(stdout)
    stdout.each_line do |line|
      if line =~ /^GLANCE_REVISION/ then
        return line.sub(/^GLANCE_REVISION=/, "").chomp
      end
    end
    return ""
  end

  def self.parse_last_message(stdout)
    failure_msg=""
    stdout.each_line do |line|
      if line =~ /^FAILURE_MSG/ then
        failure_msg = line.sub(/^FAILURE_MSG=/, "").chomp
      end
    end
    return failure_msg
  end

end
