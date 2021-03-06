require 'bcrypt'
require 'tzinfo'
require 'event_bus'
require_relative 'time_concerns'

DEFAULT_WAKE_UP_HOUR = 7
DEFAULT_WAKE_UP_MINUTE = 0
DEFAULT_GO_TO_SLEEP_MINUTE = 0
DEFAULT_GO_TO_SLEEP_HOUR = 22

class User
  include MongoMapper::Document
  extend ModelAddOns::TimeConcerns
  SCHEMA = {
    "type" => "object",
    "required" => [],
    "additionalProperties" => false,
    "properties" => {
      "user_id" => {"type" => "integer"},
      "password" => {"type" => "string"},
      "email" => {"type" => "string"},
      "first_name" => {"type" => "string"},
      "last_name" => {"type" => "string"},
      "role" => {"type" => "string"},
      "languages" => {"type" => "array"},
    }
  }
  safe

  many :devices, :foreign_key => :user_id, :class_name => "Device"
  many :abuse_reports
  one :reset_password_token, :foreign_key => :reset_password_token_id, :class_name => "ResetPasswordToken"

  key :password_hash, String
  key :password_salt, String
  key :email, String, :required => true, :unique => true
  key :first_name, String, :required => true
  key :last_name, String, :required => true
  #The iso 639-1 2 letter code
  key :languages, Array, :default => ["da","en"]
  key :user_id, Integer, :unique => true #, :required => true #Unique identifier from FB
  key :role, String, :required => true
  key :available_from, Time
  key :snooze_period, String
  key :blocked, Boolean, :default => false
  key :is_external_user, Boolean, :default => false
  key :utc_offset, Integer, :default => 2
  key :wake_up, String, :default => "07:00"
  key :go_to_sleep, String, :default => "22:00"
  key :wake_up_in_seconds_since_midnight, Integer, :default => 0
  key :go_to_sleep_in_seconds_since_midnight, Integer, :default => 0
  key :auth_token, String, :unique => true
  key :expiry_time, Time
  key :inactive, Boolean, :default => false

  timestamps!

  before_save :encrypt_password
  before_create :set_unique_id
  before_save :convert_times_to_utc
  after_save :user_saved

  before_validation :generate_auth_token

  #this is a scope
  def self.asleep_users
    now = Time.now.utc
    now_in_seconds_since_midnight = time_to_seconds_since_midnight now, 0

    where(
      "$or" => [
        {:go_to_sleep_in_seconds_since_midnight.lte => now_in_seconds_since_midnight},
        {:wake_up_in_seconds_since_midnight.gte => now_in_seconds_since_midnight}
      ])
  end

  def is_logged_in?()
    return Time.now < self.expiry_time
  end

  def reset_expiry_time
    now = Time.now
    self.expiry_time = Time.new(now.year, now.month, now.day, 0, 0, 0) - 1.days.to_i
  end

  #should be called on each login
  def create_or_renew_token()
    calculate_expiry_time()
  end


  def self.authenticate_using_email(email, password)
    user = User.first(:email => { :$regex => /#{Regexp.escape(email)}/i })

    if user.nil? || user.is_external_user
      TheLogger.log.info "User trying to log in with password, but is external user or nil"
      return nil
    end

    if !user.nil?
      return authenticate_password(user, password)
    end

    return nil
  end

  def self.authenticate_using_user_id(email, user_id)
    user = User.first(:user_id => user_id)
    if !user.nil?
      return user
    end

    return nil
  end

  def password=(pwd)
    @password = pwd
  end

  def snooze
    if self.available_from && Time.now.utc < self.available_from
      { "period" => self.snooze_period,
        "until" => self.available_from
      }
    else
      nil
    end
  end

  def to_json()
    return { "id" => self._id,
             "user_id" => self.user_id,
             "email" => self.email,
             "first_name" => self.first_name,
             "last_name" => self.last_name,
             "role" => self.role,
             "languages" => self.languages,
             "snooze" => self.snooze,
             "auth_token" => auth_token,
             "expiry_time" => expiry_time,
             "facebook_user" => is_external_user
    }.to_json
  end

  def to_s
    "#{self.first_name}"
  end

  private
  def generate_auth_token()
    # don't generate auth_token twice
    unless self.auth_token.nil?
      return
    end
    self.auth_token = create_unique_auth_token
  end

  def create_unique_auth_token
    auth_token = SecureRandom.uuid
    if User.where(:auth_token => auth_token).count > 0
      self.generate_auth_token
    end
    auth_token
  end


  def calculate_expiry_time()
    now = Time.now
    self.expiry_time = Time.new(now.year, now.month, now.day, 0, 0, 0) + 30.days.to_i
  end

  def user_saved
    EventBus.announce(:user_saved, user_id: _id)
  end

  def convert_times_to_utc
    wake_up_time = Time.parse(wake_up)
    go_to_sleep_time = Time.parse(go_to_sleep)
    self.wake_up_in_seconds_since_midnight = User.time_to_seconds_since_midnight wake_up_time, utc_offset
    self.go_to_sleep_in_seconds_since_midnight = User.time_to_seconds_since_midnight go_to_sleep_time, utc_offset
  end

 
  def self.authenticate_password(user, password)
    if user && user.password_hash == BCrypt::Engine.hash_secret(password, user.password_salt)
      return user
    end

    return nil
  end

  def encrypt_password
    if @password.present?
      self.password_salt = BCrypt::Engine.generate_salt
      self.password_hash = BCrypt::Engine.hash_secret(@password, password_salt)
    end
  end

  def generate_unique_id
    rand = ("817173" + rand(9999999).to_s.center(8, rand(9).to_s)).to_i
    if User.where(:user_id => rand).count > 0
      generate_unique_id
    else
      return rand
    end
  end

  def set_unique_id
    unless self.user_id
      unique_id =  generate_unique_id
      self.user_id = unique_id
    end
  end
end
