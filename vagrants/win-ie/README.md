Based off of: https://gist.github.com/anthonysterling/7cb85670b36821122a4a

This is meant to be replacement for ievms, as it should offer all of the
provisioning that ievms provides, plus all of the other niceties that vagrant
offers... plus, we can automatically enable bidirectional copy+paste in the
Vagranfile.

These .box-en were provided by Microsoft, but unfortunately, they're (currently)
not fully provisioned to take advantage of such vagrant features such as 'halt'
'provision', and 'reload' (and Windows normally do not have 'ssh' available.)
This is also the reason why we're getting the red:

  "Timed out while waiting for the machine to boot..."

message as 'vagrant up' never completes "successfully".

Another big advantage (over ievms) this Vagrantfile offers, is that it's able to
take as snapshot before the first boot. We can use thie revert point after the
30-day trial period has passed. Ievms does take a "clean" snapshot but it's
taken after the first boot (which it has to do to apply it's provisioning.)

TODO?:

Currently still using the GUI, but will utimately use RDP

https://dennypc.wordpress.com/2014/06/09/creating-a-windows-box-with-vagrant-1-6/
  https://dennypc.wordpress.com/2014/12/02/vagrant-provisioning-powershell-dsc/
http://www.hyper-world.de/en/2014/07/26/windows8-1-vagrant-box/
http://www.grouppolicy.biz/2014/05/enable-winrm-via-group-policy/

Create a snapshot via something like (from ievms) :

  VBoxManage snapshot "${vm}" take clean --description "The initial VM state"

upon first "up"

http://superuser.com/questions/701735/run-script-on-host-machine-during-vagrant-up
  https://github.com/phinze/vagrant-host-shell
  https://github.com/emyl/vagrant-triggers

http://www.hurryupandwait.io/blog/in-search-of-a-light-weight-windows-vagrant-box

https://www.reddit.com/r/vagrant/comments/2vza9b/has_anyone_had_luck_setting_up_the_modernie/
https://gist.github.com/andreptb/57e388df5e881937e62a
From ievms: VBoxManage guestcontrol "${vm}" run --username "${guest_user}" --password "${guest_pass}" --exe "${image}" -- cmd.exe /c copy "E:\\${2}" "${3}"
A Windows 10 with Edge browser vagrant .box file doesn't seem to be available yet.
Ievms uses: https://az792536.vo.msecnd.net/vms/VMBuild_20150801/VirtualBox/MSEdge/Mac/Microsoft%20Edge.Win10.For.Mac.VirtualBox.zip
