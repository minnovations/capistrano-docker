namespace :docker do
  def container_name
    @container_name ||= "#{fetch(:application)}-#{fetch(:stage)}"
  end


  def upload_file(file, path, options={})
    mod = options[:mod] || 'u+rw,go+r'
    tmp_file = "#{fetch(:tmp_dir)}/#{Array.new(10) { [*'0'..'9'].sample }.join}"

    upload! file, tmp_file
    sudo :cp, '-f', tmp_file, path
    sudo :chmod, mod, path
    execute :rm, '-f', tmp_file
  end


  def with_verbose_logging
    SSHKit.config.output_verbosity = :debug
    yield
  ensure
    SSHKit.config.output_verbosity = fetch(:log_level)
  end




  desc 'Setup app'
  task setup_app: [:'deploy:check', :setup_app_init, :setup_app_log_rotate, :setup_app_symlinks]


  desc 'Setup app init'
  task :setup_app_init do
    init_script = <<-eos
#!/bin/sh

### BEGIN INIT INFO
# Provides:          #{container_name}
# Required-Start:    docker
# Required-Stop:     docker
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: #{container_name}
# Description:       #{container_name}
### END INIT INFO

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

case ${1} in
  start)
    cd #{current_path}
    docker-compose up -d #{container_name}
    ;;
  stop)
    if (docker ps -a | grep -q #{container_name}) ; then
      docker stop #{container_name}
      docker rm -f #{container_name}
    fi
    ;;
esac
eos

    on roles(:app) do
      upload_file(StringIO.new(init_script), "/etc/init.d/#{container_name}", mod: 'u=rwx,go=rx')
      sudo :chkconfig, container_name, 'on'
    end
  end


  desc 'Setup app log rotate'
  task :setup_app_log_rotate do
    log_rotate_script = <<-eos
#{shared_path}/log/*.log {
  daily
  rotate 7
  compress
  copytruncate
  delaycompress
  missingok
  notifempty
}
eos

    on roles(:app) do
      upload_file(StringIO.new(log_rotate_script), "/etc/logrotate.d/#{container_name}")
      sudo :chmod, '-R', 'ugo+rw', "#{shared_path}/log"
    end
  end


  desc 'Setup app symlinks'
  task :setup_app_symlinks do
    on roles([:web, :app, :db]) do
      execute :ln, '-sf', current_path, "~/#{container_name}"
    end
  end




  desc 'Deploy app'
  task deploy_app: [:build_app, :restart_app, :cleanup_images]

  after 'deploy:publishing', :deploy_app


  desc 'Build app'
  task :build_app do
    on roles(:app) do
      within current_path do
        with_verbose_logging do
          sudo :'docker-compose', 'build', container_name
        end
      end
    end
  end


  desc 'Start app'
  task :start_app do
    on roles(:app) do
      within current_path do
        sudo :'docker-compose', 'up', '-d', container_name
      end
    end
  end


  desc 'Stop app'
  task :stop_app do
    on roles(:app) do
      sudo :bash, '-c', "\"if (docker ps -a | grep -q #{container_name}) ; then docker stop #{container_name} ; docker rm -f #{container_name} ; fi\""
    end
  end


  desc 'Restart app'
  task restart_app: [:stop_app, :start_app]


  desc 'Run app command'
  task :run_app_command, :command do |t, args|
    on roles(:app) do
      within current_path do
        sudo :'docker-compose', 'run', '--rm', container_name, args[:command]
      end
    end
  end




  desc 'Cleanup containers'
  task :cleanup_containers do
    on roles(:app) do
      sudo :bash, '-c', '"for CONTAINER in \$(docker ps -f status=exited -q) ; do docker rm \${CONTAINER} ; done"'
    end
  end


  desc 'Cleanup images'
  task :cleanup_images do
    on roles(:app) do
      sudo :bash, '-c', '"for IMAGE in \$(docker images -f dangling=true -q) ; do docker rmi \${IMAGE} ; done"'
    end
  end
end
