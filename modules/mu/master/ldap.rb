#!/usr/local/ruby-current/bin/ruby
# Copyright:: Copyright (c) 2014 eGlobalTech, Inc., all rights reserved
#
# Licensed under the BSD-3 license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License in the root of the project or at
#
#     http://egt-labs.com/mu/LICENSE.html
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'net-ldap'

module MU
  class Master
    class LDAP
      class MuLDAPError < MU::MuError;end
      require 'date'

      # Make sure the LDAP section of $MU_CFG makes sense.
      def self.validateConfig
        ok = true
        supported = ["Active Directory", "389 Directory Services"]
        if !$MU_CFG
          raise "Configuration not loaded yet, but MU::Master::LDAP.validateConfig was called!"
        end
        if !$MU_CFG.has_key?("ldap")
          raise MuLDAPError "Missing 'ldap' section of config (files: #{$MU_CFG['config_files']})"
        end
        ldap = $MU_CFG["ldap"] # shorthand
        if !ldap.has_key?("type") or !supported.include?(ldap["type"])
          ok = false
          MU.log "Bad or missing 'type' of LDAP server (should be one of #{supported})", MU::ERR
        end
        ["base_dn", "user_ou", "domain_name", "domain_netbios_name", "user_group_dn", "user_group_name", "admin_group_dn", "admin_group_name"].each { |var|
          if !ldap.has_key?(var) or !ldap[var].is_a?(String)
            ok = false
            MU.log "LDAP config section parameter '#{var}' is missing or is not a String", MU::ERR
          end
        }
        if !ldap.has_key?("dcs") or !ldap["dcs"].is_a?(Array) or ldap["dcs"].size < 1
          ok = false
          MU.log "Missing or empty 'dcs' section of LDAP config"
        end
        ["bind_creds", "join_creds"].each { |creds|
          if !ldap.has_key?(creds) or !ldap[creds].is_a?(Hash) or
             !ldap[creds].has_key?("vault") or !ldap[creds].has_key?("item") or
             !ldap[creds].has_key?("username_field") or
             !ldap[creds].has_key?("password_field")
            MU.log "LDAP config subsection '#{creds}' misconfigured, should be hash containing: vault, item, username_field, password_field", MU::ERR
            ok = false
            next
          end
          loaded = MU::Groomer::Chef.getSecret(vault: ldap[creds]["vault"], item: ldap[creds]["item"])
          if !loaded or !loaded.has_key?(ldap[creds]["username_field"]) or
              loaded[ldap[creds]["username_field"]].empty? or
              !loaded.has_key?(ldap[creds]["password_field"]) or
              loaded[ldap[creds]["password_field"]].empty?
            MU.log "LDAP config subsection '#{creds}' refers to a bogus vault or incorrect/missing item fields", MU::ERR, details: ldap[creds]
            ok = false
          end
        }
        if !ok
          raise MuLDAPError, "One or more LDAP configuration errors from files #{$MU_CFG['config_files']}"
        end
      end

      @ldap_conn = nil
      @gid_attr = "cn"
      @member_attr = "uniqueMember"
      @uid_attr = "uid"
      @group_class = "groupofuniquenames"
      @uid_range_start = 10000
      # Create and return a connection to our directory service. If we've
      # already opened one, return that.
      # @return [Net::LDAP]
      def self.getLDAPConnection
        return @ldap_conn if @ldap_conn
        validateConfig
        if $MU_CFG["ldap"]["type"] == "Active Directory"
          @gid_attr = "sAMAccountName"
          @member_attr = "member"
          @uid_attr = "sAMAccountName"
          @group_class = "group"
        end
        bind_creds = MU::Groomer::Chef.getSecret(vault: $MU_CFG["ldap"]["bind_creds"]["vault"], item: $MU_CFG["ldap"]["bind_creds"]["item"])
        @ldap_conn = Net::LDAP.new(
          :host => $MU_CFG["ldap"]["dcs"].first,
          :encryption => :simple_tls,
          :port => 636,
          :base => $MU_CFG["ldap"]["base_dn"],
          :auth => {
            :method => :simple,
            :username => bind_creds[$MU_CFG["ldap"]["bind_creds"]["username_field"]],
            :password => bind_creds[$MU_CFG["ldap"]["bind_creds"]["password_field"]]
          }
        )
        @ldap_conn
      end

      # Intended to run when Mu's local LDAP server has been created. Use the
      # root credentials to populate our OU structure, create other users, etc.
      # This only needs to understand a 389 Directory style schema, since
      # obviously we're not running Active Directory locally on Linux.
      def self.initLocalLDAP
        validateConfig
        if $MU_CFG["ldap"]["type"] != "389 Directory Services" or
            !$MU_CFG["ldap"]["dcs"].include?("localhost")
          MU.log "Custom directory service configured, not initializing bundled schema", MU::NOTICE
          return
        end
        root_creds = MU::Groomer::Chef.getSecret(vault: "mu_ldap", item: "root_dn_user")
        @ldap_conn = Net::LDAP.new(
          :host => "127.0.0.1",
          :encryption => :simple_tls,
          :port => 636,
          :base => "",
          :auth => {
            :method => :simple,
            :username => root_creds["username"],
            :password => root_creds["password"]
          }
        )

        # Manufacture our OU tree and groups
        [$MU_CFG["ldap"]["base_dn"],
          "OU=Mu-System,#{$MU_CFG["ldap"]["base_dn"]}",
          $MU_CFG["ldap"]["user_ou"],
          $MU_CFG["ldap"]["user_group_dn"],
          $MU_CFG["ldap"]["admin_group_dn"]
        ].each { |full_dn|
          dn = ""
          full_dn.split(/,/).reverse.each { |chunk|
            if dn.empty?
              dn = chunk
            else
              dn = "#{chunk},#{dn}"
            end
            next if chunk.match(/^DC=/i)
            if chunk.match(/^OU=(.*)/i)
              ou = $1
              if !@ldap_conn.add(
                    :dn => dn,
                    :attributes => {
                      :ou => ou, 
                      :objectclass =>"organizationalUnit"
                    }
                  ) and @ldap_conn.get_operation_result.code != 68 # "already exists"
                MU.log "Error creating #{dn}: "+getLDAPErr, MU::ERR
                return false
              elsif @ldap_conn.get_operation_result.code != 68
                MU.log "Created OU #{dn}", MU::NOTICE
              end
            elsif chunk.match(/^CN=(.*)/i)
              group = $1
              attr = {
                :cn => group,
                :description => "#{group} Group",
                :objectclass => ["top", "groupofuniquenames"]
              }
              if !@ldap_conn.add(
                    :dn => dn,
                    :attributes => attr
                  ) and @ldap_conn.get_operation_result.code != 68
                MU.log "Error creating #{dn}: "+getLDAPErr, MU::ERR, details: attr
                return false
              elsif @ldap_conn.get_operation_result.code != 68
                MU.log "Created group #{dn}", MU::NOTICE
              end
            end
          }
        }
         
        ["bind_creds", "join_creds"].each { |creds|
          data = MU::Groomer::Chef.getSecret(vault: $MU_CFG["ldap"][creds]["vault"], item: $MU_CFG["ldap"][creds]["item"])
          user_dn = data[$MU_CFG["ldap"][creds]["username_field"]]
          user_dn.match(/^CN=(.*?),/i)
          username = $1
          pw = data[$MU_CFG["ldap"][creds]["password_field"]]

          attr = {
            :cn => username,
            :displayName => "Mu Service Account",
            :objectclass => ["top", "person", "organizationalPerson", "inetorgperson"],
            :uid => username,
            :mail => $MU_CFG['mu_admin_email'],
            :givenName => "Mu",
            :sn => "Service",
            :userPassword => pw
          }
          if !@ldap_conn.add(
                :dn => data[$MU_CFG["ldap"][creds]["username_field"]],
                :attributes => attr
              ) and @ldap_conn.get_operation_result.code != 68
            pp attr
            raise MU::MuError, "Failed to create user #{user_dn} (#{getLDAPErr})"
          elsif @ldap_conn.get_operation_result.code != 68
            MU.log "Created #{username} (#{user_dn})", MU::NOTICE
          end

          # Set the password
          if !@ldap_conn.replace_attribute(user_dn, :userPassword, [pw])
            MU.log "Couldn't update password for user #{username}.", MU::ERR, details: getLDAPErr
          end

          # Grant this user appropriate privileges
          targets = []
          if creds == "bind_creds"
            targets << $MU_CFG["ldap"]["user_ou"]
            targets << $MU_CFG["ldap"]["user_group_dn"]
            targets << $MU_CFG["ldap"]["admin_group_dn"]
          elsif creds == "join_creds"
# XXX Some machine-related OU?
          end
          targets.each { | target|
            aci = "(targetattr=\"*\")(target=\"ldap:///#{target}\")(version 3.0; acl \"#{username} admin privileges for #{target}\"; allow (all) userdn=\"ldap:///#{user_dn}\";)"
            if !@ldap_conn.modify(:dn => $MU_CFG["ldap"]["base_dn"], :operations => [[:add, :aci, aci]]) and @ldap_conn.get_operation_result.code != 20
              MU.log "Couldn't modify permissions for user #{username}.", MU::ERR, details: getLDAPErr
            elsif @ldap_conn.get_operation_result.code != 20
              MU.log "Granted #{username} user admin privileges over #{target}", MU::NOTICE
            end
          }
        }
      end

      # Shorthand for fetching the most recent error on the active LDAP
      # connection
      def self.getLDAPErr
        return nil if !@ldap_conn
        return @ldap_conn.get_operation_result.code.to_s+" "+@ldap_conn.get_operation_result.message.to_s
      end

      # Approximate a current Microsoft timestamp. They count the number of
      # 100-nanoseconds intervals (1 nanosecond = one billionth of a second)
      # since Jan 1, 1601 UTC.
      def self.getMicrosoftTime
        ms_epoch = DateTime.new(1601,1,1)
        # this is in milliseconds, so multiply it for the right number of zeroes
        elapsed = DateTime.now.strftime("%Q").to_i - ms_epoch.strftime("%Q").to_i
        return elapsed*10000
      end

      # Convert a Microsoft timestamp to a Ruby Time object. See also #getMicrosoftTime.
      # @param stamp [Integer]: The MS-style timestamp, e.g. 130838184558490696
      # @return [Time]
      def self.convertMicrosoftTime(stamp)
        ms_epoch = DateTime.new(1601,1,1).strftime("%Q").to_i
        unixtime = (stamp.to_i/10000) + DateTime.new(1601,1,1).strftime("%Q").to_i
        Time.at(unixtime/1000)
      end

      @can_write = nil
      # Test whether our LDAP binding user has permissions to create other
      # users, manipulate groups, and set passwords. Note that it's *not* fatal
      # if we can't, simply a design where most account management happens on
      # the directory side.
      # @return [Boolean]
      def self.canWriteLDAP?
        return @can_write if !@can_write.nil?

        conn = getLDAPConnection
        dn = "CN=Mu Testuser #{Process.pid},#{$MU_CFG["ldap"]["user_ou"]}"
        attr = {
          :cn => "Mu Testuser #{Process.pid}",
          @uid_attr.to_sym => "mu.testuser.#{Process.pid}"
        }
        group_attr = :uniqueMember
        if $MU_CFG["ldap"]["type"] == "Active Directory"
          attr[:objectclass] = ["user"]
          attr[:userPrincipalName] = "mu.testuser.#{Process.pid}@#{$MU_CFG["ldap"]["domain_name"]}"
          attr[:pwdLastSet] = "-1"
          group_attr = :member
        elsif $MU_CFG["ldap"]["type"] == "389 Directory Services"
          attr[:objectclass] = ["top", "person", "organizationalPerson", "inetorgperson"]
          attr[:userPassword] = Password.pronounceable(12..14)
          attr[:displayName] = "Mu Test User #{Process.pid}"
          attr[:mail] = $MU_CFG['mu_admin_email']
          attr[:givenName] = "Mu"
          attr[:sn] = "TestUser"
        end

        @can_write = true
        if !conn.add(:dn => dn, :attributes => attr)
          MU.log "Couldn't create write-test user #{dn}, operating in read-only LDAP mode", MU::NOTICE, details: getLDAPErr
          return false
        end

        # Make sure we can write various fields that we might need to touch
        [:displayName, :mail, :givenName, :sn].each { |field|
          if !conn.replace_attribute(dn, field, "foo@bar.com")
            MU.log "Couldn't modify write-test user #{dn} field #{field.to_s}, operating in read-only LDAP mode", MU::NOTICE, details: getLDAPErr
            @can_write = false
            break
          end
        }

        # Can we add them to the Mu membership group(s)
        [$MU_CFG["ldap"]["user_group_dn"], $MU_CFG["ldap"]["admin_group_dn"]].each { |group|
          if !conn.modify(:dn => group, :operations => [[:add, group_attr, dn]])
            MU.log "Couldn't add write-test user #{dn} to group #{group}, operating in read-only LDAP mode", MU::NOTICE, details: getLDAPErr
            @can_write = false
          end
        }

        if !conn.delete(:dn => dn)
          MU.log "Couldn't delete write-test user #{dn}, operating in read-only LDAP mode", MU::NOTICE
          @can_write = false
        end

        @can_write
      end

      # Search for groups whose names contain any of the given search terms and
      # return their full DNs.
      # @param search [Array<String>]: Strings to search for.
      # @param exact [Boolean]: Return only exact matches for whole fields.
      # @param searchbase [String]: The DN under which to search.
      # @return [Array<String>]
      def self.findGroups(search = [], exact: false, searchbase: $MU_CFG['ldap']['base_dn'])
        if search.nil? or search.size == 0
          raise MuError, "Need something to search for in MU::Master::LDAP.findGroups"
        end
        conn = getLDAPConnection
        filter = nil
        search.each { |term|
          curfilter = Net::LDAP::Filter.contains(@gid_attr, "#{term}")
          if exact
            curfilter = Net::LDAP::Filter.eq(@gid_attr, "#{term}")
          end

          if !filter
            filter = curfilter
          else
            filter = filter | curfilter
          end
        }
        filter = Net::LDAP::Filter.ne("objectclass", "computer") & (filter)
        groups = []
        conn.search(
          :filter => filter,
          :base => searchbase,
          :attributes => ["objectclass"]
        ) do |group|
          groups << group.dn
        end
        groups
      end

      # See https://technet.microsoft.com/en-us/library/ee198831.aspx
      AD_PW_ATTRS = {
        'script' => 0x0001, #SCRIPT
        'disable' => 0x0002, #ACCOUNTDISABLE
        'homedirRequired' => 0x0008, #HOMEDIR_REQUIRED
        'lockout' => 0x0010, #LOCKOUT
        'noPwdRequired' => 0x0020, #ADS_UF_PASSWD_NOTREQD
        'cantChangePwd' => 0x0040, #ADS_UF_PASSWD_CANT_CHANGE
        'pwdStoredReversible' => 0x0080, #ADS_UF_ENCRYPTED_TEXT_PASSWORD_ALLOWED
        'tempDuplicateAccount' => 0x0100, #NORMAL_ACCOUNT
        'normal' => 0x0200, #NORMAL_ACCOUNT
        'pwdNeverExpires' => 0x10000, #ADS_UF_DONT_EXPIRE_PASSWD
        'pwdExpired' => 0x80000, #ADS_UF_PASSWORD_EXPIRED
        'trustedToAuthForDelegation' => 0x1000000 #TRUSTED_TO_AUTH_FOR_DELEGATION
      }.freeze

      # Find a directory user with fuzzy string matching on sAMAccountName/uid, displayName, group memberships, or email
      # @param search [Array<String>]: Strings to search for.
      # @param exact [Boolean]: Return only exact matches for whole fields.
      # @param searchbase [String]: The DN under which to search.
      # @return [Array<Hash>]
      def self.findUsers(search = [], exact: false, searchbase: $MU_CFG['ldap']['base_dn'], extra_attrs: [])
        # We want to search groups, but can't search on memberOf with wildcards.
        # So search groups independently, build a list of full CNs, and use
        # those.
        if search.size > 0
          groups = findGroups(search, exact: exact, searchbase: searchbase)
        end
        searchattrs = [@uid_attr]
        getattrs = []
        if $MU_CFG["ldap"]["type"] == "389 Directory Services"
          getattrs = ["uid", "displayName", "mail"] + extra_attrs
        elsif $MU_CFG["ldap"]["type"] == "Active Directory"
          getattrs = ["sAMAccountName", "displayName", "mail", "lastLogon", "lockoutTime", "pwdLastSet", "memberOf", "userAccountControl"] + extra_attrs
        end
        if !exact
          searchattrs = searchattrs + ["displayName", "mail"] + extra_attrs
        end

        conn = getLDAPConnection
        users = {}
        filter = nil
        rejected = 0
        if search.size > 0
          search.each { |term|
            if term.length < 4 and !exact
              MU.log "Search term '#{term}' is too short, ignoring.", MU::WARN
              rejected = rejected + 1
              next
            end
            searchattrs.each { |attr|
              if !filter
                if exact
                  filter = Net::LDAP::Filter.eq(attr, "#{term}")
                else
                  filter = Net::LDAP::Filter.contains(attr, "#{term}")
                end
              else
                if exact
                  filter = filter |Net::LDAP::Filter.eq(attr, "#{term}")
                else
                  filter = filter |Net::LDAP::Filter.contains(attr, "#{term}")
                end
              end
            }
          }
          if rejected == search.size
            MU.log "No valid search strings provided.", MU::ERR
            return nil
          end
        end
        if groups
          groups.each { |group|
            filter = filter |Net::LDAP::Filter.eq("memberOf", group)
          }
        end
        if filter 
          filter = Net::LDAP::Filter.ne("objectclass", "computer") & Net::LDAP::Filter.ne("objectclass", "group") & (filter)
        else
          filter = Net::LDAP::Filter.ne("objectclass", "computer") & Net::LDAP::Filter.ne("objectclass", "group")
        end
        conn.search(
          :filter => filter,
          :base => searchbase,
          :attributes => getattrs
        ) do |acct|
          begin
            next if users.has_key?(acct[@uid_attr].first)
          rescue NoMethodError
            next
          end
          users[acct[@uid_attr].first] = {}
          users[acct[@uid_attr].first]['dn'] = acct.dn
          getattrs.each { |attr|
            begin
              if acct[attr].size == 1
                users[acct[@uid_attr].first][attr] = acct[attr].first
              else
                users[acct[@uid_attr].first][attr] = acct[attr]
              end
              if attr == "userAccountControl"
                AD_PW_ATTRS.each_pair { |pw_attr, bitmask|
                  if (bitmask | acct[attr].first.to_i) == acct[attr].first.to_i
                    users[acct[@uid_attr].first][pw_attr] = true
                  end
                }
                users[acct[@uid_attr].first][attr] = acct[attr].first.to_i.to_s(2)
              end
            end rescue NoMethodError
          }
        end
        users
      end

      # @return [Array<String>]
      def self.listUsers
        conn = getLDAPConnection
        users = {}

        ["admin_group_name", "user_group_name"].each { |group|
          groupname_filter = Net::LDAP::Filter.eq(@gid_attr, $MU_CFG["ldap"][group])
          group_filter = Net::LDAP::Filter.eq("objectClass", @group_class)
          member_cns = []
          conn.search(
            :filter => Net::LDAP::Filter.join(groupname_filter, group_filter),
            :attributes => [@member_attr]
          ) do |item|
            member_cns = item[@member_attr].dup
          end
          member_cns.each { |member|
            cn = member.dup.sub(/^CN=([^\,]+?),.*/i, "\\1")
            searchbase = member.dup.sub(/^CN=[^\,]+?,(.*)/i, "\\1")
            conn.search(
              :filter => Net::LDAP::Filter.eq("cn",cn),
              :base => searchbase,
              :attributes => [@uid_attr, "displayName", "mail"]
            ) do |acct|
              next if users.has_key?(acct[@uid_attr].first)
              users[acct[@uid_attr].first] = {}
              users[acct[@uid_attr].first]['dn'] = acct.dn
              if group == "admin_group_name"
                users[acct[@uid_attr].first]['admin'] = true
              else
                users[acct[@uid_attr].first]['admin'] = false
              end
              begin
                users[acct[@uid_attr].first]['realname'] = acct.displayname.first
              end rescue NoMethodError
              begin
                users[acct[@uid_attr].first]['email'] = acct.mail.first
              end rescue NoMethodError
            end
          }
        }
        users
      end

      def self.deleteUser(user)
        if canWriteLDAP?
          conn = getLDAPConnection
          dn = nil
          conn.search(
            :filter => Net::LDAP::Filter.eq(@uid_attr, user),
            :base => $MU_CFG["ldap"]["base_dn"],
            :attributes => [@uid_attr]
          ) do |acct|
            dn = acct.dn
            break
          end
          return false if dn.nil?
          # Our default LDAP server doesn't cascade user deletes through groups,
          # so help it out.
          if $MU_CFG["ldap"]["type"] == "389 Directory Services"
            conn.search(
              :filter => Net::LDAP::Filter.eq("objectclass", "groupofuniquenames"),
              :base => $MU_CFG["ldap"]["base_dn"],
              :attributes => ["cn", "uniqueMember"]
            ) do |group|
              group.uniquemember.each { |member|
                if member.downcase == dn.downcase
                  manageGroup(group.cn.first, remove_users: [user])
                end
              }
            end
          end
          if !conn.delete(:dn => dn)
            MU.log "Failed to delete #{user} from LDAP: #{getLDAPErr}", MU::WARN, details: dn
            return false
          end
          MU.log "Removed LDAP user #{user}", MU::NOTICE
          return true
        else
          MU.log "We are in read-only LDAP mode. You must manually delete #{user} from your directory.", MU::WARN
        end

        false
      end

      # Add/remove users to/from a group.
      # @param group [String]: The short name of the group
      # @param add_users [Array<String>]: The short names of users to add to the group
      # @param remove_users [Array<String>]: The short names of users to remove from the group
      def self.manageGroup(group, add_users: [], remove_users: [])
        group_dn = findGroups([group], exact: true).first
        if !group_dn or group_dn.empty?
          raise MuError, "Failed to find a Distinguished Name for group #{group}"
        end
        if (add_users & remove_users).size > 0
          raise MuError, "Can't both add and remove the same user (#{(add_users & remove_users).join(", ")}) from a group"
        end
        add_users = findUsers(add_users, exact: true) if add_users.size > 0
        remove_users = findUsers(remove_users, exact: true) if remove_users.size > 0
        group_attr = :uniqueMember
        group_attr = :member if $MU_CFG["ldap"]["type"] == "Active Directory"

        conn = getLDAPConnection
        if add_users.size > 0
          add_users.each_pair { |user, data|
            if !conn.modify(:dn => group_dn, :operations => [[:add, group_attr, data["dn"]]])
              MU.log "Couldn't add user #{user} (#{data['dn']}) to group #{group} (#{group_dn}).", MU::WARN, details: getLDAPErr
            else
              MU.log "Added #{user} to group #{group}", MU::NOTICE
            end
          }
        end
        if remove_users.size > 0
          remove_users.each_pair { |user, data|
            if !conn.modify(:dn => group_dn, :operations => [[:delete, group_attr, data["dn"]]])
              MU.log "Couldn't remove user #{user} (#{data['dn']}) from group #{group} (#{group_dn}).", MU::WARN, details: getLDAPErr
            else
              MU.log "Removed #{user} from group #{group}", MU::NOTICE
            end
          }
        end
      end

      # Call when creating or modifying a user.
      # @param user [String]: The username on which to operate
      # @param password [String]: Set the user's password
      # @param email [String]: Set the user's email address
      # @param admin [Boolean]: Whether to flag this user as an admin
      # @param mu_acct [Boolean]: Whether to operate on users outside of Mu (generic directory users)
      # @param ou [String]: The OU into which to deposit new users.
      def self.manageUser(user, name: nil, password: nil, email: nil, admin: false, mu_acct: true, ou: $MU_CFG["ldap"]["user_ou"])
        cur_users = listUsers

        first = last = nil
        if !name.nil?
          last = name.split(/\s+/).pop
          first = name.split(/\s+/).shift
        end
        conn = getLDAPConnection

        # If we're operating on users that aren't specifically Mu users,
        # fetch generic directory information about them instead of the Mu
        # user descriptor.
        if !mu_acct
          cur_users = findUsers([user], exact: true)
        end

        # Oh, Microsoft. Slap quotes around it, convert it to Unicode, and call
        # it Sally. *Then* it's a password.
        password_attr = :userPassword
        if !password.nil? and $MU_CFG["ldap"]["type"] == "Active Directory"
          ascii_pw = '"'+password+'"'
          password = ""
          ascii_pw.length.times{|i| password+= "#{ascii_pw[i..i]}\000" }
          password_attr = :unicodePwd
        end

        ok = true
        if !cur_users.has_key?(user)
          # Creating a new user
          if canWriteLDAP?
            if password.nil? or email.nil? or name.nil?
              raise MU::MuError, "Missing one or more required fields (name, password, email) creating new user #{user}"
            end
            user_dn = "CN=#{name},#{ou}"
            conn = getLDAPConnection
            attr = {
              :cn => name,
              :displayName => name,
              :givenName => first,
              :sn => last,
              :mail => email,
              :userPassword => password,
            }
            if $MU_CFG["ldap"]["type"] == "389 Directory Services"
              attr[:objectclass] = ["top", "person", "organizationalPerson", "inetorgperson"]
              attr[:uid] = user
              # Nothing stops external programs from stealing a uid from under
              # us. Ugh. A mapping might be n
              MU::MommaCat.lock("uid_generator", false, true)
              used_uids = []
              Etc.passwd{ |u|
                if u.name == user and mu_acct
                  raise "Username #{user} already exists as a system user, cannot allocate in directory"
                end
                used_uids << u.uid
              }
              for x in @uid_range_start..65535 do
                if !used_uids.include?(x)
                  attr[:employeeNumber] = x.to_s
                  break
                end
              end
            elsif $MU_CFG["ldap"]["type"] == "Active Directory"
              attr[:objectclass] = ["user"]
              attr[:samaccountname] = user
              attr[:userAccountControl] = AD_PW_ATTRS['normal'].to_s
              attr[:userPrincipalName] = "#{user}@#{$MU_CFG["ldap"]["domain_name"]}"
              attr[:pwdLastSet] = "-1"
              if mu_acct
                attr[:userAccountControl] = (attr[:userAccountControl].to_i & AD_PW_ATTRS['pwdNeverExpires']).to_s
              end
            end
            if !conn.add(:dn => user_dn, :attributes => attr)
              MU::MommaCat.unlock("uid_generator", true)
              raise MU::MuError, "Failed to create user #{user} (#{getLDAPErr})"
            end
            MU::MommaCat.unlock("uid_generator", true)
            attr[:userPassword] = "********"
            MU.log "Created new LDAP user #{user}", details: attr
            groups = []
            if mu_acct
              groups << $MU_CFG["ldap"]["user_group_name"]
              groups << $MU_CFG["ldap"]["admin_group_name"] if admin
            end
            groups.each { |group|
              manageGroup(group, add_users: [user])
            }

            # We now require the system to know that the user exists. Sometimes
            # winbind takes a minute to catch on.
            wait = 5
            begin
              %x{/usr/bin/getent passwd}
              Etc.getpwnam(user)
            rescue ArgumentError
              if wait >= 30
                MU.log "User #{user} has been created in LDAP, but local system can't see it. Are PAM/LDAP/Winbind configured correctly?", MU::ERR
                return false
              end
              MU.log "User #{user} has been created in LDAP, but not yet visible to local system, waiting #{wait}s and checking again.", MU::WARN
              sleep wait
              wait = wait + 5
              retry
            end
            %x{/sbin/restorecon -r /home} # SELinux stupidity that oddjob misses
            gid = MU::Master.setLocalDataPerms(user)
            if $MU_CFG["ldap"]["type"] == "389 Directory Services"
              # Make sure we have a sensible default gid
              conn.replace_attribute(user_dn, :departmentNumber, gid.to_s)
            end
          else
            MU.log "We are in read-only LDAP mode. You must first create #{user} in your directory and add it to #{$MU_CFG["ldap"]["user_group_dn"]}. If the user is intended to be an admin, also add it to #{$MU_CFG["ldap"]["admin_group_dn"]}.", MU::WARN
            return true
          end
        else
          gid = MU::Master.setLocalDataPerms(user)
          # Modifying an existing user
          if canWriteLDAP?
            conn = getLDAPConnection
            user_dn = cur_users[user]['dn']
            if $MU_CFG["ldap"]["type"] == "389 Directory Services"
              # Make sure we have a sensible default gid
              conn.replace_attribute(user_dn, :departmentNumber, gid.to_s)
            end
            if !name.nil? and cur_users[user]['realname'] != name
              MU.log "Updating display name for #{user} to #{name}", MU::NOTICE
              conn.replace_attribute(user_dn, :displayName, name)
              conn.replace_attribute(user_dn, :givenName, first)
              conn.replace_attribute(user_dn, :sn, last)
              cur_users[user]['realname'] = name
            end
            if !email.nil? and cur_users[user]['email'] != email
              MU.log "Updating email for #{user} to #{email}", MU::NOTICE
              conn.replace_attribute(user_dn, :mail, email)
              cur_users[user]['email'] = email
            end
            if !password.nil?
              MU.log "Updating password for #{user}", MU::NOTICE
              if !conn.replace_attribute(user_dn, password_attr, [password])
                MU.log "Couldn't update password for user #{user}.", MU::WARN, details: getLDAPErr
                ok = false
              end
            end
            if admin and !cur_users[user]['admin']
              MU.log "Granting Mu admin privileges to #{user}", MU::NOTICE
              manageGroup($MU_CFG["ldap"]["admin_group_name"], add_users: [user])
            elsif !admin and cur_users[user]['admin']
              MU.log "Revoking Mu admin privileges from #{user}", MU::NOTICE
              manageGroup($MU_CFG["ldap"]["admin_group_name"], remove_users: [user])
            end
          else
            MU.log "We are in read-only LDAP mode. You must manage #{user} in your directory.", MU::WARN
          end
        end
        return ok if !mu_acct # everything below is Mu-specific
        cur_users = MU::Master.listUsers

        ["realname", "email", "monitoring_email"].each { |field|
          next if !cur_users[user].has_key?(field)
          File.open($MU_CFG['datadir']+"/users/#{user}/#{field}", File::CREAT|File::RDWR, 0640) { |f|
            f.puts cur_users[user][field]
          }
        }
        MU::Master.setLocalDataPerms(user)
        ok
      end

    end
  end
end
