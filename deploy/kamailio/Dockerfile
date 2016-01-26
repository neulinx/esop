FROM centos:6		
MAINTAINER Gary Hai "gary@XL59.com"		

# -------------------- Yum installs
RUN yum update -y
RUN yum install -y epel-release
RUN curl -o /etc/yum.repos.d/kamailio.repo -s http://download.opensuse.org/repositories/home:/kamailio:/v4.3.x-rpms/CentOS_6/home:kamailio:v4.3.x-rpms.repo
RUN yum install -y kamailio
		
# Expose the default SIP server port		
EXPOSE 5060		
		
# Set the default command to run when starting the container		
CMD ["/usr/sbin/kamailio", "-DD","-P", "/var/run/kamailio.pid", "-f", "/etc/kamailio/kamailio.cfg"]
