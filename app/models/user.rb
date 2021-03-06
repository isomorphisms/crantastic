# == Schema Information
#
# Table name: user
#
#  id                  :integer(4)      not null, primary key
#  login               :string(255)
#  email               :string(255)
#  crypted_password    :string(255)
#  password_salt       :string(255)
#  created_at          :datetime
#  updated_at          :datetime
#  activated_at        :datetime
#  remember            :boolean(1)      default(FALSE), not null
#  homepage            :string(255)
#  profile             :text
#  profile_html        :text
#  single_access_token :string(255)     default(""), not null
#  role_name           :string(40)
#  perishable_token    :string(40)
#  persistence_token   :string(128)     default(""), not null
#  login_count         :integer(4)      default(0), not null
#  last_request_at     :datetime
#  last_login_at       :datetime
#  current_login_at    :datetime
#  last_login_ip       :string(255)
#  current_login_ip    :string(255)
#  tos                 :boolean(1)
#

require "rpx_now/user_integration"

class User < ActiveRecord::Base

  include RPXNow::UserIntegration # Adds rpx.identifiers, rpx.map, and rpx.unmap
  include RFC822

  acts_as_authentic do |c|
    c.act_like_restful_authentication = true

    c.perishable_token_valid_for = 1.day

    c.validates_format_of_login_field_options = {
      :with => /^\w[\w\.\-_@]+$/,
      :message => "only use letters, numbers, and .-_@ please"
    }
    c.validates_format_of_email_field_options = {
      :with => EmailAddress,
      # JS validation by Scott Gonzalez: http://projects.scottsplayground.com/email_address_validation/
      :message => "is not a valid email address"
    }
    c.merge_validates_format_of_email_field_options :if => Proc.new { |user| !user.from_rpx }
    c.merge_validates_length_of_email_field_options :if => Proc.new { |user| !user.from_rpx }
    c.merge_validates_format_of_login_field_options :if => Proc.new { |user| !user.from_rpx }
    c.merge_validates_length_of_login_field_options :if => Proc.new { |user| !user.from_rpx }
  end

  validates_acceptance_of :tos, :allow_nil => false, :accept => true,
                          :if => Proc.new { |user| !user.from_rpx }

  is_gravtastic # Enables the Gravtastic plugin for the User model

  default_scope :order => "id ASC"

  has_many :author_identities, :dependent => :destroy
  has_many :authors, :through => :author_identities

  has_many :reviews,        :dependent => :nullify
  has_many :taggings,       :dependent => :nullify
  has_many :package_users,  :dependent => :nullify
  has_many :packages, :through => :package_users, :order => "LOWER(package.name) ASC",
                      :conditions => "package_user.active IS TRUE"

  # Prevents a user from submitting a crafted form that bypasses activation
  # anything else you want your user to change should be added here.
  attr_accessible :login, :email, :password, :password_confirmation, :remember,
                  :homepage, :profile, :tos

  attr_accessor :from_rpx

  def to_s
    login
  end

  # Overrides authlogic, avoids any password checks for users currently signing
  # up via rpx or existing users without password (meaning that they've signup
  # via rpx and haven't set a password). =from_rpx= is only true when explicitly
  # set so via the attr_accessor.
  def require_password?
    from_rpx || (!new_record? && crypted_password.blank?) ? false : super
  end

  # Activates the user.
  def activate
    self.activated_at = Time.now.utc
    save!
  end

  def active?
    self.activated_at.not_nil?
  end

  # Rates a package, discarding the users previous rating in the process
  #
  # @param [Fixnum, Package] package
  # @param [Fixnum] rating
  # @return [PackageRating]
  def rate!(package, rating, aspect="overall")
    package = package.id if package.kind_of?(Package)
    r = rating_for(package, aspect)
    if r
      r.rating = rating
      r.save
    else
      PackageRating.create!(:package_id => package, :user_id => self.id,
                            :rating => rating, :aspect => aspect)
    end
  end

  # This users' rating for a package
  #
  # @param [Fixnum] package The primary key (id) of the package to rate
  # @param [String] aspect "general" or "documentation"
  # @return [PackageRating] The PackageRating object
  def rating_for(package_id, aspect="overall")
    PackageRating.find(:first,
                       :conditions => {
                         :package_id => package_id,
                         :user_id => self.id,
                         :aspect => aspect
                       })
  end

  # Toggle this users usage status for a given package. Creates a new vote or
  # deletes an existing one. Returns true if the user is using the package,
  # after the toggle has been performed.
  def toggle_usage(pkg)
    usage = PackageUser.find(:first, :conditions => {
                               :user_id => self, :package_id => pkg
                             })
    if usage
      res = usage.toggle!(:active) && usage.active
      res ? pkg.increment(:package_users_count) : pkg.decrement(:package_users_count)
      pkg.save
      return res
    end
    self.package_users << PackageUser.new(:package => pkg)
    true
  end

  def uses?(pkg)
    PackageUser.active.count(:conditions => ["user_id = ? AND package_id = ?",
                                             self.id, pkg.id]) == 1
  end

  def author_of?(pkg)
    # This could be optimized, but I think this will suffice for a while
    # since most of the time a user will only be connected with one author.
    self.authors.collect { |a| a.packages }.flatten.uniq.include?(pkg)
  end

  def deliver_activation_instructions!
    reset_perishable_token!
    UserMailer.deliver_activation_instructions(self)
  end

  def deliver_activation_confirmation!
    UserMailer.deliver_activation_confirmation(self)
  end

  def deliver_password_reset_instructions!
    reset_perishable_token!
    UserMailer.deliver_password_reset_instructions(self)
  end

  def admin?
    self.role_name == "administrator"
  end

end
