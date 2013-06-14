require 'fileutils'

role :base do
  task :setup do
    sudo do
      exec! 'apt-get install -y curl wget build-essential git-core vim psmisc iptables dnsutils telnet nmap', echo: true
    end
  end

  task :shutdown do
    sudo { shutdown '-h', :now }
  end

  task :reboot do
    sudo { reboot }
  end
end

role :couchdb do
  task :setup do
    sudo do
      # build tools
      exec! 'apt-get install -y build-essential libtool autoconf automake autoconf-archive pkg-config', echo: true
      # dependencies
      exec! 'apt-get install -y erlang libssl0.9.8 libssl-dev zlib1g zlib1g-dev libcurl4-openssl-dev lsb-base  ncurses-dev libncurses-dev libmozjs-dev libmozjs2d libicu-dev xsltproc', echo: true
      cd '/opt'
      unless dir? 'couchdb'
        git :clone, 'git://github.com/apache/couchdb.git', echo: true
      end
      cd 'couchdb'
      begin
        git :checkout, '1.3.0'
      end
      git :pull, echo: true
      exec! './bootstrap', echo: true
      exec! "./configure --prefix=/opt/couchdb-#{name} && make && make check && make install"
      echo File.read("/opt/couchdb-#{name}/etc/couchdb/local.ini").gsub(';port = 5984', "port = 598#{name[1]}"), to: "/opt/couchdb-#{name}/etc/couchdb/local.ini"
    end
  end

  task :deploy do
  end

  task :start do
    exec! "/opt/couchdb-#{name}/bin/couchdb"
  end

  task :stop do
    killall '-9', 'beam.smp'
  end
  
  task :restart do
    sudo do
      couchdb.stop rescue false
      couchdb.start
    end
  end

  task :ping do

  end
end

role :riak do
  task :setup do
    sudo do
      exec! 'apt-get install -y libssl0.9.8 erlang', echo: true
      cd '/opt'
      unless dir? 'riak'
        git :clone, 'git://github.com/basho/riak.git', echo: true
      end
      cd 'riak'
      begin
        git :checkout, '1.3'
      rescue
        git :checkout, '-b', '1.3', 'origin/1.3'
      end
      git :pull, echo: true
      make :distclean, echo: true
      make :rel, echo: true
    end

    riak.deploy

  end

  task :start do
    sudo do
      cd '/opt/riak/rel/riak'
      exec! 'bash -c "ulimit -n 10000 && bin/riak start"', echo: true
    end
  end
  
  task :restart do
    sudo do
      riak.stop rescue false
      riak.start
    end
  end

  task :stop do
    sudo do
      begin
        cd '/opt/riak/rel/riak'
        exec! 'bin/riak stop', echo: true
      rescue
        killall '-9', 'beam.smp'
      end
    end
  end

  task :ping do
    sudo do
      exec! '/opt/riak/rel/riak/bin/riak ping', echo: true
    end
  end

  task :tail do
    tail '-F', '/opt/riak/rel/riak/log/console.log', echo: true
  end

  task :deploy do
    riak.stop rescue nil
    sudo do
      echo File.read(__DIR__/:riak/'app.config'), to: '/opt/riak/rel/riak/etc/app.config'
      echo File.read(__DIR__/:riak/'vm.args').gsub('%%NODE%%', name), to: '/opt/riak/rel/riak/etc/vm.args'
    end
    riak.start
  end

  task :join do
    cd '/opt/riak/rel/riak'
    sudo do
      exec! 'bin/riak-admin cluster join riak@n1', echo: true
    end
  end

  task :plan do
    cd '/opt/riak/rel/riak'
    sudo do
      exec! 'bin/riak-admin cluster plan', echo: true
    end
  end

  task :commit do
    cd '/opt/riak/rel/riak'
    sudo do
      exec! 'bin/riak-admin cluster commit', echo: true
    end
  end
  
  task :ring_status do
    cd '/opt/riak/rel/riak'
    sudo do
      exec! 'bin/riak-admin ring_status', echo: true
    end
  end

  task :transfers do
    cd '/opt/riak/rel/riak'
    sudo do
      exec! 'bin/riak-admin transfers', echo: true
    end
  end
  
  task :status do
    cd '/opt/riak/rel/riak'
    sudo do
      exec! 'bin/riak-admin status', echo: true
    end
  end

  task :reset do
    sudo do
      riak.stop rescue false
      rm '-rf', '/opt/riak/rel/riak/data/*'
    end
  end

  task :nuke do
    sudo do
      begin
        riak.stop
      rescue
      end
      rm '-rf', '/opt/riak'
    end
  end
end

role :mongo do
  task :setup do
    sudo do
      unless (dpkg '-l').include? 'mongodb-10gen'
        exec! 'apt-key adv --keyserver keyserver.ubuntu.com --recv 7F0CEB10'
        echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen', to: '/etc/apt/sources.list.d/10gen.list'
        exec! 'apt-get update', echo: true
      end
      exec! 'apt-get install -y mongodb-10gen', echo: true
      begin
        mongo.start
      rescue => e
        throw unless e.message =~ /already running/
      end
    end
    
    if name == 'n1'
      log "Waiting for mongo to become available"
      loop do
        begin
          mongo '--eval', true
          break
        rescue
          sleep 1
        end
      end
      log "Initiating replica set."
      mongo.eval 'rs.initiate()'
      log "Waiting for replica set to initialize."
      until (mongo('--eval', 'rs.status().members[0].state') rescue '') =~ /1\Z/
        log mongo('--eval', 'rs.status().members')
        sleep 1
      end
      log "Assigning priority."
      mongo.eval 'c = rs.conf(); c.members[0].priority = 2; rs.reconfig(c)'
      
      log "Adding members to replica set."
      mongo.eval 'rs.add("n2")'
      mongo.eval 'rs.add("n3")'
      mongo.eval 'rs.add("n4")'
      mongo.eval 'rs.add("n5")'
    end
  end

  task :nuke do
    sudo do
      mongo.stop rescue nil
      rm '-rf', '/var/lib/mongodb/*'
    end
  end

  task :stop do
    sudo { service :mongodb, :stop, echo: true }
  end

  task :start do
    sudo { service :mongodb, :start, echo: true }
  end

  task :restart do
    sudo { service :mongodb, :restart, echo: true }
  end

  task :tail do
    tail '-F', '/var/log/mongodb/mongodb.log', echo: true
  end

  task :eval do |str|
    unless (str =~ /;/)
      str = "printjson(#{str})"
    end

    mongo '--eval', str, echo: true
  end

  task :rs_conf do
    mongo.eval 'rs.conf()'
  end

  task :rs_status do
    mongo.eval 'rs.status()'
  end

  task :rs_stat do
    mongo.eval 'rs.status().members.map(function(m) { print(m.name + " " + m.stateStr + "\t" + m.optime.t + "/" + m.optime.i); }); true'
  end

  task :deploy do
    sudo do
      echo File.read(__DIR__/:mongo/'mongodb.conf').gsub('%%NODE%%', name), to: '/etc/mongodb.conf'
    end
    mongo.eval 'c = rs.conf(); c.members[0].priority = 2; rs.reconfig(c);'
    mongo.restart
  end

  task :flip do
    if name != "n1"
      mongo.eval 'rs.stepDown(30)'
    end
  end

  task :reset do
    sudo do
      if dir? '/var/lib/mongdb/rollback'
        find '/var/lib/mongodb/rollback/', '-iname', '*.bson', '-delete'
      end
      find '/var/log/mongodb/', '-iname', '*.log', '-delete'
      mongo.restart
    end
  end

  # Grabs logfiles and data files and tars them up
  task :collect do
    d = 'mongo-collect/' + name
    FileUtils.mkdir_p d

    # Logs
    download '/var/log/mongodb/mongodb.log', d

    # Oplogs
    #oplogs = d/:oplogs
    #FileUtils.mkdir_p oplogs
    #cd '/tmp'
    #rm '-rf', 'mongo-collect'
    #mkdir 'mongo-collect'
    #mongodump '-d', 'local', '-c', 'oplog.rs', '-o', 'mongo-collect', echo: true
    #cd 'mongo-collect/local'
    #find('*.bson').split("\n").each do |f|
    #  log oplogs
    #  download f, oplogs
    #end
    #cd '/tmp'
    #rm '-rf', 'mongo-collect'

    # Data dirs
    rb = '/var/lib/mongodb/rollback'
    if dir? rb
      FileUtils.mkdir_p "#{d}/rollback"
      find(rb, '-iname', '*.bson').split("\n").each do |f|
        download f, "#{d}/rollback"
      end
    end
  end

  task :rollbacks do
    if dir? '/var/lib/mongodb/rollback'
      find('/var/lib/mongodb/rollback/',
           '-iname', '*.bson').split("\n").each do |f|
        bsondump f, echo: true
      end
      ls '-lah', '/var/lib/mongodb/rollback', echo: true 
    end
  end
end

role :redis do
  task :setup do
    sudo do
      cd '/opt/'
      unless dir? :redis
        git :clone, 'git://github.com/antirez/redis.git', echo: true
      end
      cd :redis
      make :clean, echo: true
      make echo: true
#      make :test, echo: true
    end
  end

  task :start do
    cd '/opt/redis/src'
    sudo do
      if name == 'n1'
        # master
        exec! 'bash -c "ulimit -n 10000 && ./redis-server"', echo: true
      else
        exec! 'bash -c "ulimit -n 10000 && ./redis-server --slaveof n1 6379"', echo: true
      end
    end
  end

  task :sentinel do
    sudo do
      echo "port 26379
sentinel monitor mymaster #{dig '+short', name} 6379 3
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 900000
sentinel can-failover mymaster yes
sentinel parallel-syncs mymaster 5", to: '/opt/redis/sentinel.config'
      cd '/opt/redis/src'
      exec! './redis-sentinel /opt/redis/sentinel.config', echo: true
    end
  end

  task :stop do
    sudo do
      killall 'redis-server' rescue log "no redis-server"
      killall 'redis-sentinel' rescue log "no redis-sentinel"
    end
  end

  task :replication do
    sudo do
      exec! '/opt/redis/src/redis-cli info replication', echo: true
    end
  end
end

role :postgres do
  task :setup do
    sudo do
      exec! 'apt-get install -y postgresql-9.1', echo: true
      exec! 'locale-gen en_US.UTF-8'
      sudo_upload __DIR__/:postgres/'postgresql.conf',
        '/etc/postgresql/9.1/main/postgresql.conf'
      sudo_upload __DIR__/:postgres/'pg_hba.conf',
        '/etc/postgresql/9.1/main/pg_hba.conf'
      service :postgresql, :restart
    end
    sudo :postgres do
      begin
        createuser '--pwprompt', '--no-createdb', '--no-superuser',
          '--no-createrole', 'jepsen', stdin: "jepsen\njepsen\n", echo: true
        createdb '--owner=jepsen', 'jepsen', echo: true
      rescue
      end
    end
  end
end

role :jepsen do
  task :setup do
    base.setup
    riak.setup
    mongo.setup
    redis.setup
    postgres.setup
  end
 
  task :slow do
    sudo { exec! 'tc qdisc add dev eth0 root netem delay 50ms 10ms distribution normal' }
  end

  task :flaky do
    sudo { exec! 'tc qdisc add dev eth0 root netem loss 20% 75%' }
  end

  task :fast do
    sudo { tc :qdisc, :del, :dev, :eth0, :root }
  end

  task :partition do
    sudo do
      n3 = dig '+short', :n3
      n4 = dig '+short', :n4
      n5 = dig '+short', :n5
      if ['n1', 'n2'].include? name
        log "Partitioning from n3, n4 and n5."
        iptables '-A', 'INPUT', '-s', n3, '-j', 'DROP'
        iptables '-A', 'INPUT', '-s', n4, '-j', 'DROP'
        iptables '-A', 'INPUT', '-s', n5, '-j', 'DROP'
      end
      iptables '--list', echo: true
    end
  end

  task :partition_reject do
    sudo do
      n1 = dig '+short', :n1
      n2 = dig '+short', :n2
      n3 = dig '+short', :n3
      n4 = dig '+short', :n4
      n5 = dig '+short', :n5
      if ['n1', 'n2'].include? name
        log "Partitioning from n3, n4 and n5."
        iptables '-A', 'INPUT', '-s', n3, '-j', 'REJECT'
        iptables '-A', 'INPUT', '-s', n4, '-j', 'REJECT'
        iptables '-A', 'INPUT', '-s', n5, '-j', 'REJECT'
      else
        log "Partitioning from n1, n2"
        iptables '-A', 'INPUT', '-s', n1, '-j', 'REJECT'
        iptables '-A', 'INPUT', '-s', n2, '-j', 'REJECT'
      end

      iptables '--list', echo: true
    end
  end

  task :drop_pg do
    sudo do
      log "Dropping all PG traffic."
      iptables '-A', 'INPUT', '-p', 'tcp', '--dport', 5432, '-j', 'DROP'
      iptables '--list', echo: true
    end
  end

  task :heal do
    sudo do
      iptables '-F', echo: true
      iptables '-X', echo: true
      iptables '--list', echo: true
    end
  end

  task :status do
    sudo do
      iptables '--list', echo: true
    end
  end
end

group :jepsen do
  host :n1
  host :n2
  host :n3
  host :n4
  host :n5
  
  each_host do
    user :ubuntu
    role :base
    role :postgres
    role :redis
    role :mongo
    role :riak
    role :jepsen
    @password = 'ubuntu'
  end
end
