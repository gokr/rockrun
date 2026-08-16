# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrant setup for cross-building Rockrun for Windows x64.
# Box: Windows 10 with Chocolatey; provisioning steps are defined with
# --provision-with (see makewindows.sh / makeorxwindows.sh):
#   build-orx      - clones Norx, builds orx.dll
#   build-rockrun  - builds rockrun.exe with the bundled orx.dll
# First-time setup: boot the VM, run C:\vagrant\scripts\windows-setup.bat
# as Administrator (installs Chocolatey, Git, Nim, MinGW).
Vagrant.configure("2") do |config|
  config.vm.box = "gusztavvargadr/windows-10"
  config.vm.box_version = "2511.0.0"

  # Share the repo into the VM
  config.vm.synced_folder ".", "c:/Users/vagrant/shared", type: "virtualbox"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "4096"
    vb.cpus = 4
  end

  # Build ORX dlls (used by makeorxwindows.sh)
  config.vm.provision "build-orx", type: "shell", path: "scripts/build-orx.bat",
    args: ["c:/Users/vagrant/shared"]

  # Build the rockrun.exe
  config.vm.provision "build-rockrun", type: "shell", path: "scripts/build-rockrun.bat",
    args: ["c:/Users/vagrant/shared"]
end
