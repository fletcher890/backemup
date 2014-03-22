#!/usr/bin/env ruby

=begin

  * Name: Backemup
  * Description: The script loops through all the websites on the server. It creates a sql file and the zips everything up and pushes it to amazon s3 cloud storgage.
  * Author: Simon Fletcher & Jack Cutting on behalf of Logic Design and Consultancy LTD
  * Date: 20/03/2014
  * Copyright (c) 2014 Logic Design and Consultancy LTD

   Permission is hereby granted, to any person that wishes 
   to review the code, but they cannot use it or change it in any way.

=end

require "fileutils"
require "digest/sha1"
require 'net/smtp'

HOSTING_PATH = "/var/www/vhosts/"
HOSTING_LAYOUT = "/httpdocs"


# Ignore the directories that you do not want to backuup

IGNORE_PROJECTS = [
	'fs-passwd',
	'.',
	'..',
	'.skel',
	'fs',
	'chroot',
	'default',
	'system'
]

HOSTNAME = `echo $HOSTNAME`.strip!
@databases = []

# filter_projects() - runs through all folders within the HOSTING_PATH (these have to be websites)

def filter_domains(ps)
	ps = ps.map {|p| p.strip}
	ps.select do |p|
		IGNORE_PROJECTS.index(p) == nil && File.directory?(content_dir(p))
	end
end


# getdbs() - gets all the databases on the server and puts them into a hash with the relating domain name as the key

def getdbs

	dbs = `mysql -uadmin -p$(cat /etc/psa/.psa.shadow) -Dpsa -e "SELECT d.name AS DOMAIN, db.name AS DB FROM db_users du, data_bases db, domains d, accounts a WHERE du.db_id = db.id AND db.dom_id=d.id and du.account_id=a.id ORDER BY d.name, db.name;"`
	dbs = dbs.split(/\r?\n/)
	databases = {}
	dbs.each_with_index do |d, index|
		if index == 0
			next
		else
			parts = d.split(/\t/)
			databases[parts[0]] = parts[1]
		end
	end
	@databases = databases
end

# getdb() - takes a sql dump of the database that is requested through the @name variable. This will be stored within the website file directory until the back up is complete.

def getdb(domain)
	
	dir_name = content_dir(domain)
	dbdb = @databases[domain]
	
	if !@databases[domain].nil?
		`mysqldump -uadmin -p$(cat /etc/psa/.psa.shadow) #{dbdb} > #{dir_name}/#{domain}.sql`
	end

end

# tarballit() - creates a backup of the given folder the file structure will look like the following: backup-2014-03-19-10-19-30-15b043d8d47e4d07676e0bb7b5d7168629748e02.tar.gz. This also removes the dbdump that you have created previously.

def tarballit(domain)
	time = Time.now
	time = time.strftime("%Y-%m-%d-%H-%M-%S")
	hash = Digest::SHA1.hexdigest domain
	filename = "backup-#{time}-#{hash}.tar.gz"
	source = content_dir(domain)
	tarball = "#{source}/#{filename}"

	getdb(domain)

	`cd #{source} && tar -pczf #{filename} .`
	sendtos3(domain, tarball, filename)

	remove_db_backup(domain)

end


# sentos3() - Moves the backup to the amazon s3.

def sendtos3(domain, tarball, filename)
	hostname = `echo $HOSTNAME`
	hostname.strip!
	
	`aws s3 mv #{tarball} s3://logictestbackups/#{hostname}/#{domain}/ --acl public-read`
end


# firstofthemonth() - This checks to see if it is the first of the month. If it is, it will move the last backup into the archive area and clear the folder on amazon s3

def firstofthemonth(domain)
	
	if Date.today.day == 1
	
		date = Time.now
		this_month = date.strftime('%m')
		last_month = this_month.to_i - 1
		year = date.strftime('%Y')
	
		if last_month == 0
			last_month = 12
			year = year -1
		end

		latest_backup = get_backup(domain, 'newist')
		
		`aws s3 mv s3://logictestbackups/#{HOSTNAME}/#{domain}/#{latest_backup} s3://logictestbackups/#{HOSTNAME}/archive/#{domain}/#{year}/#{last_month}/#{latest_backup} --pulic-read`
	end

end

# get_backup() - returns either the newest, oldest or all of the zips on the amazon s3 within the given domain.

def get_backup(domain, type = 'oldest')
	list = `aws s3 ls s3://logictestbackups/#{HOSTNAME}/#{domain}/`
	list = list.split(/\r?\n/)
	arr = []
	list.each do |f|
		arr.push(f.split(' '))
	end

	if type == 'newist'
		file = arr.last
		return file.last
	elsif type == 'oldest'
		file = arr.first
		return file.last
	elsif type == 'arr'
		return arr
	end
end

# removeoldest() - removes the oldest zip file if there are more than 10 backups on the amazon s3 server

def removeoldest(domain)

	arr = get_backup(domain, 'arr')
	file = get_backup(domain)
	if arr.count >= 10	
	 `aws s3 rm s3://logictestbackups/#{HOSTNAME}/#{domain}/#{file}`
	end

end

# content_dir() - simple bootstraping function for the file path

def content_dir(p)
	HOSTING_PATH + p + HOSTING_LAYOUT
end

# remove_db_backup() - removes the backup from the given domain name provided by the @domain variable

def remove_db_backup(domain)
	`rm -f #{content_dir(domain)}/#{domain}.sql`
end

# sendmail() - runs a completion email once all of the websites have been backed up.

def sendmail(domains)

	domains = domains.join("\r\n")

	message = <<MESSAGE_END
From: Server <server@example.co.uk>
To: John Doe <john@example.co.uk>
Subject: Backup Complete

The following domains have been backed up:-

#{domains}

MESSAGE_END

Net::SMTP.start('localhost') do |smtp|
  smtp.send_message message, 'john@example.com', 'john@example.com'
end

end

# backup() - this orchestrates the backup

def backup(domain) 

	firstofthemonth(domain)
	tarballit(domain)
	removeoldest(domain)

end


hosting = Dir.new(HOSTING_PATH)
domains = filter_domains(hosting.entries)
getdbs()

# Loop through the domains and run backup()

domains.each do |domain|
	backup(domain)
end

# Run complete email
sendmail(domains)

