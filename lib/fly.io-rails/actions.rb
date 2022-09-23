require 'thor'
require 'active_support'
require 'active_support/core_ext/string/inflections'
require 'fly.io-rails/machines'
require 'fly.io-rails/utils'

module Fly
  class Actions < Thor::Group
    include Thor::Actions
    include Thor::Base
    include Thor::Shell
    attr_accessor :options

    def initialize(app = nil)
      self.app = app if app

      @ruby_version = RUBY_VERSION
      @bundler_version = Bundler::VERSION
      @node = File.exist? 'node_modules'
      @yarn = File.exist? 'yarn.lock'
      @node_version = @node ? `node --version`.chomp.sub(/^v/, '') : '16.17.0'
      @org = Fly::Machines.org
      @regions = []

      @options = {}
      @destination_stack = [Dir.pwd]
    end

    def app
      return @app if @app
      self.app = TOML.load_file('fly.toml')['app']
    end

    def app=(app)
      @app = app
      @appName = @app.gsub('-', '_').camelcase(:lower)
    end

    source_paths.push File::expand_path('../generators/templates', __dir__)

    def generate_toml
      app
      template 'fly.toml.erb', 'fly.toml'
    end

    def generate_dockerfile
      app
      template 'Dockerfile.erb', 'Dockerfile'
    end

    def generate_dockerignore
      app
      template 'dockerignore.erb', '.dockerignore'
    end

    def generate_terraform
      app
      template 'main.tf.erb', 'main.tf'
    end

    def generate_raketask
      app
      template 'fly.rake.erb', 'lib/tasks/fly.rake'
    end

    def generate_all
      generate_dockerfile
      generate_dockerignore
      generate_terraform
      generate_raketask
    end

    def generate_ipv4
      cmd = 'flyctl ips allocate-v4'
      say_status :run, cmd
      system cmd
    end

    def generate_ipv6
      cmd = 'flyctl ips allocate-v6'
      say_status :run, cmd
      system cmd
    end

    def create_volume(app, region, size)
      volume = "#{app.gsub('-', '_')}_volume"
      volumes = JSON.parse(`flyctl volumes list --json`).
        map {|volume| volume[' Name']}

      unless volumes.include? volume
        cmd = "flyctl volumes create #{volume} --app #{app} --region #{region} --size #{size}"
        say_status :run, cmd
        system cmd
      end

      volume
    end

    def create_postgres(app, org, region, vm_size, volume_size, cluster_size)
      cmd = "fly postgres create --name #{app}-db --org #{org} --region #{region} --vm-size #{vm_size} --volume-size #{volume_size} --initial-cluster-size #{cluster_size}"
      say_status :run, cmd
      output = FlyIoRails::Utils.tee(cmd)
      output[%r{postgres://\S+}]
   end

    def release(app, config)
      start = Fly::Machines.create_start_machine(app, config: config)
      machine = start[:id]

      if !machine
	STDERR.puts 'Error starting release machine'
	PP.pp start, STDERR
	exit 1
      end

      # wait for release to copmlete
      status = nil
      5.times do
	status = Fly::Machines.wait_for_machine app, machine,
          timeout: 60, status: 'stopped'
	return machine if status[:ok]
      end

      STDERR.puts status.to_json
      exit 1
    end

    def deploy(app, image) 
      regions = JSON.parse(`flyctl regions list --json`)['Regions'].
        map {|region| region['Code']} rescue []
      region = regions.first || 'iad'

      secrets = JSON.parse(`fly secrets list --json`).
        map {|secret| secret["Name"]}

      config = {
        region: region,
        app: app,
        name: "#{app}-machine",
        image: image,
        guest: {
          cpus: 1,
          cpu_kind: "shared",
          memory_mb: 256,
        },
        services: [
	  {
	    ports: [
	      {port: 443, handlers: ["tls", "http"]},
	      {port: 80, handlers: ["http"]}
	    ],
	    protocol: "tcp",
	    internal_port: 8080
	  } 
        ]
      }

      database = YAML.load_file('config/database.yml').
        dig('production', 'adapter') rescue nil
      cable = YAML.load_file('config/cable.yml').
        dig('production', 'adapter') rescue nil

      if database == 'sqlite3'
        volume = create_volume(app, region, 3) 

        config[:mounts] = [
          { volume: volume, path: '/mnt/volume' }
        ]

        config[:env] = {
          "DATABASE_URL" => "sqlite3:///mnt/volume/production.sqlite3"
        }
      elsif database == 'postgresql' and not secrets.include? 'DATABASE_URL'
        secret = create_postgres(app, @org, region, 'shared-cpu-1x', 1, 1)

        cmd = "fly secrets set DATABASE_URL=#{secret}"
        say_status :run, cmd
        system cmd
      end

      # build config for release machine, overriding server command
      release_config = config.dup
      release_config.delete :services
      release_config.delete :mounts
      release_config[:env] = { 'SERVER_COMMAND' => 'bin/rails fly:release' }

      # perform release
      say_status :fly, release_config[:env]['SERVER_COMMAND']
      machine = release(app, release_config)
      Fly::Machines.delete_machine app, machine if machine

      # start proxy, if necessary
      endpoint = Fly::Machines::fly_api_hostname!

      # start app
      say_status :fly, "start #{app}"
      start = Fly::Machines.create_start_machine(app, config: config)
      machine = start[:id]

      if !machine
	STDERR.puts 'Error starting application'
	PP.pp start, STDERR
	exit 1
      end

      5.times do
	status = Fly::Machines.wait_for_machine app, machine,
          timeout: 60, status: 'started'
	return if status[:ok]
      end

      STDERR.puts 'Timeout waiting for application to start'
    end

    def terraform(app, image) 
      # update main.tf with the image name
      tf = IO.read('main.tf')
      tf[/^\s*image\s*=\s*"(.*?)"/, 1] = image.strip
      IO.write 'main.tf', tf

      # find first machine in terraform config file
      machines = Fly::HCL.parse(IO.read('main.tf')).find {|block|
	block.keys.first == :resource and
	block.values.first.keys.first == 'fly_machine'}

      # extract HCL configuration for the machine
      config = machines.values.first.values.first.values.first

      # delete HCL specific configuration items
      %i(services for_each region app name depends_on).each do |key|
	 config.delete key
      end

      # move machine configuration into guest object
      config[:guest] = {
	cpus: config.delete(:cpus),
	memory_mb: config.delete(:memorymb),
	cpu_kind: config.delete(:cputype)
      }

      # release machines should have no services or mounts
      config.delete :services
      config.delete :mounts

      # override start command
      config[:env] ||= {}
      config[:env]['SERVER_COMMAND'] = 'bin/rails fly:release'

      # start proxy, if necessary
      endpoint = Fly::Machines::fly_api_hostname!

      # start release machine
      STDERR.puts "--> #{config[:env]['SERVER_COMMAND']}"
      start = Fly::Machines.create_start_machine(app, config: config)
      machine = start[:id]

      if !machine
	STDERR.puts 'Error starting release machine'
	PP.pp start, STDERR
	exit 1
      end

      # wait for release to copmlete
      event = nil
      90.times do
	sleep 1
	status = Fly::Machines.get_a_machine app, machine
	event = status[:events]&.first
	break if event && event[:type] == 'exit'
      end

      # extract exit code
      exit_code = event.dig(:request, :exit_event, :exit_code)
	       
      if exit_code == 0
	# delete release machine
	Fly::Machines.delete_machine app, machine

	# use terraform apply to deploy
	ENV['FLY_API_TOKEN'] = `flyctl auth token`.chomp
	ENV['FLY_HTTP_ENDPOINT'] = endpoint if endpoint
	system 'terraform apply -auto-approve'
      else
	STDERR.puts 'Error performing release'
	STDERR.puts (exit_code ? {exit_code: exit_code} : event).inspect
	STDERR.puts "run 'flyctl logs --instance #{machine}' for more information"
	exit 1
      end
    end
  end
end