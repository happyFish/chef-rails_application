#
# Cookbook Name:: rails_application
# Recipe:: application
#
# Copyright 2013, Devops Israel
#
# All rights reserved - Do Not Redistribute
#
if node[:rails][:app][:name].split(" ").count > 1
  Chef::Application.fatal!("Application name must be one word long !")
end

include_recipe "runit"

include_recipe "git" # install git, no support for svn for now

include_recipe "ruby::#{node[:rails][:ruby][:version]}" # install ruby
include_recipe "ruby::symlinks"

# create deploy user & group
user node[:rails][:owner] do
  Chef::Log.info("create user #{node[:rails][:owner]}")
  action :create

  supports manage_home => true
  notifies :run, "execute[generate_ssh_key_for_#{node[:rails][:owner]}]"
end


directory File.join('/','home',node[:rails][:owner]) do
  owner node[:rails][:owner]
  group node[:rails][:group]
end


group node[:rails][:group] do
  action :create
  members node[:rails][:owner]
end

execute "generate_ssh_key_for_#{node[:rails][:owner]}"  do
  action :nothing # only run when user is created

  Chef::Log.info("generate_ssh_key_for_#{node[:rails][:owner]}")

  user node[:rails][:owner]
  command "ssh-keygen -t rsa -q -f /home/#{node[:rails][:owner]}/.ssh/id_rsa -P \"\" && cp /home/#{node[:rails][:owner]}/.ssh/id_rsa.pub /tmp/#{node[:rails][:owner]}.pub"

  notifies :run, "execute[add_repo_to_known_hosts]"
  notifies :run, "execute[add_ssh_key_to_git_server]"
end

# add git repo to known hosts, so future deploys won't be interrupted
execute "add_repo_to_known_hosts" do
  action :nothing # only run when ssh key is created

  Chef::Log.info "add_repo_to_known_hosts"

  user "#{node[:rails][:owner]}"
  command "ssh-keyscan -H #{node[:rails][:deploy][:repository].split(/@|:/)[1]} >> /home/#{node[:rails][:owner]}/.ssh/known_hosts"
end

# send id_rsa.pub over to Bitbucket as a new deploy key
execute "add_ssh_key_to_git_server" do
  action :nothing # only run when ssh key is created
  Chef::Log.info "add_ssh_key_to_git_server"

  command "scp /tmp/#{node[:rails][:owner]}.pub git_olite@justizroush.cc:~/git.justizroush.cc/keydir/deploy@#{node['fqdn'].sub('.', '-')}.pub; ssh git_olite@justizroush.cc \"cd git.justizroush.cc/keydir && git add . && git commit -m \"added deploy key for #{node['fqdn'].sub('.', '-')}\" && git push\""
end

# save generated or provided database password in the node itself
node.set[:rails][:database][:password] = node[:rails][:database][:password]
node.set[:rails][:database][:username] = node[:rails][:database][:username]
node.set[:rails][:database][:name] = node[:rails][:database][:name]

# can't put node[:rails][...] things inside the database block
db_host     = node[:rails][:database][:host]
db_name     = node[:rails][:database][:name]
db_username = node[:rails][:database][:username]
db_password = node[:rails][:database][:password]
db_adapter  = node[:rails][:database][:adapter]

application node[:rails][:app][:name] do
  action    node[:rails][:deploy][:action]
  path      node[:rails][:app][:path]

  if node[:rails][:deploy][:ssh_key]
    deploy_key node[:rails][:deploy][:ssh_key]
  end

  repository        node[:rails][:deploy][:repository]
  revision          node[:rails][:deploy][:revision]
  enable_submodules node[:rails][:deploy][:enable_submodules]
  shallow_clone     node[:rails][:deploy][:shallow_clone]

  environment_name node[:rails][:app][:environment]

  packages   node[:rails][:packages]
  owner      node[:rails][:owner]
  group      node[:rails][:group]

  # symlink/remove/create various things during deploys
  purge_before_symlink       node[:rails][:deploy][:purge_before_symlink]
  create_dirs_before_symlink node[:rails][:deploy][:create_dirs_before_symlink]
  symlinks                   node[:rails][:deploy][:symlinks]
  symlink_before_migrate     node[:rails][:deploy][:symlink_before_migrate]

  # useful commands
  migrate           node[:rails][:deploy][:migrate]
  migration_command node[:rails][:deploy][:migration_command]
  restart_command   node[:rails][:deploy][:restart_command]

  rails do
    bundler                node[:rails][:deploy][:bundler]
    bundle_command         node[:rails][:deploy][:bundle_command]
    bundler_deployment     node[:rails][:deploy][:bundler_deployment]
    bundler_without_groups node[:rails][:deploy][:bundler_without_groups]
    precompile_assets      node[:rails][:deploy][:precompile_assets]
    database_master_role   node[:rails][:deploy][:database_master_role]
    database_template      node[:rails][:deploy][:database_template]

    gems                   node[:rails][:gems] | [ "bundler" ]
    # can't put node[:rails][...] things inside the database block
    database do
      adapter  db_adapter
      host     db_host
      database db_name
      username db_username
      password db_password
    end

  end

  before_deploy do

    execute "upstart-reload-configuration" do
      command "/sbin/initctl reload-configuration"
      action [:nothing]
    end

    # use upstart for unicorn
    template "/etc/init/unicorn_#{node[:rails][:app][:name]}.conf" do
      mode 0644
      cookbook cookbook_name.to_s
      source "unicorn.conf.erb"
      owner "root"
      group "root"
      notifies :run, "execute[upstart-reload-configuration]", :immediately
      variables(
        app_name:         node[:rails][:app][:name],
        app_path:         File.join(node[:rails][:app][:path], "current"),
        rails_env:        node[:rails][:app][:environment],
        rails_user:       node[:rails][:owner],
        rails_group:      node[:rails][:group],
        nginx_user:       node[:nginx][:user],
        nginx_group:      node[:nginx][:group],
        socket:           node[:rails][:unicorn][:port],
        bundler:          node[:rails][:unicorn][:bundler],
        bundle_command:   node[:rails][:unicorn][:bundle_command],
        unicorn_bin:      node[:rails][:unicorn][:unicorn_bin],
        unicorn_config:   node[:rails][:unicorn][:unicorn_config]
      )
    end

    service "unicorn_#{node[:rails][:app][:name]}" do
      provider Chef::Provider::Service::Upstart
      supports status: true, restart: true
      action :nothing
    end

  end

  unicorn do

    worker_processes node[:rails][:unicorn][:worker_processes]
    worker_timeout   node[:rails][:unicorn][:worker_timeout]
    preload_app      node[:rails][:unicorn][:preload_app]
    before_fork      node[:rails][:unicorn][:before_fork]
    port             node[:rails][:unicorn][:port]
    bundler          node[:rails][:unicorn][:bundler]
    bundle_command   node[:rails][:unicorn][:bundle_command]

    # Figure this out.
    # forked_user      node[:rails][:owner]
    # forked_group     node[:rails][:group]

    restart_command  do  # when a string is used, it will run it as owner/group not as root!
      service "unicorn_#{node[:rails][:app][:name]}" do
        provider Chef::Provider::Service::Upstart
        action [ :restart ]
      end
    end

  end

  nginx_load_balancer do
    #### defaults ###
    template            node[:rails][:nginx][:template]
    server_name         node[:rails][:nginx][:server_name]
    port                node[:rails][:nginx][:port]
    application_port    node[:rails][:nginx][:application_port]
    static_files        node[:rails][:nginx][:static_files]   # eg. { "/img" => "images" }
    ssl                 node[:rails][:nginx][:ssl]
    ssl_certificate     node[:rails][:nginx][:ssl_certificate]
    ssl_certificate_key node[:rails][:nginx][:ssl_certificate_key]
  end

end

