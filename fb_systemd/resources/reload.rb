# vim: syntax=ruby:expandtab:shiftwidth=2:softtabstop=2:tabstop=2

actions :run
default_action :run

attribute :instance, :kind_of => String, :default => 'system'
attribute :user, :kind_of => [String, NilClass], :default => nil
