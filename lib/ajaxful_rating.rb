module AjaxfulRating # :nodoc:
  class AlreadyRatedError < StandardError
    def to_s
      "Model has already been rated by this user. To allow update of ratings pass :allow_update => true to the ajaxful_rateable call."
    end
  end

  def self.included(base)
    base.extend ClassMethods
  end

  module ClassMethods
    attr_reader :options

    # Extends the model to be easy ajaxly rateable.
    #
    # Options:
    # * <tt>:stars</tt> Max number of stars that can be submitted.
    # * <tt>:allow_update</tt> Set to true if you want users to be able to update their votes.
    # * <tt>:cache_column</tt> Name of the column for storing the cached rating average.
    #
    # Example:
    #   class Article < ActiveRecord::Base
    #     ajaxful_rateable :stars => 10, :cache_column => :custom_column
    #   end
    def ajaxful_rateable(options = {})
      has_many :rates, :as => :rateable, :dependent => :destroy, :conditions => "dimension IS NULL"

      if options[:dimensions]
        options[:dimensions].each do |dimension|
          has_many "#{dimension}_rates".to_sym, :dependent => :destroy, :conditions => "dimension = '#{dimension}'", :class_name => 'Rate', :as => :rateable
        end
      end
      
      @options = options.reverse_merge(
        :stars => 5,
        :allow_update => true,
        :cache_column => :rating_average
      )
      include AjaxfulRating::InstanceMethods
      extend AjaxfulRating::SingletonMethods
    end

    # Makes the association between user and Rate model.
    def ajaxful_rater(options = {})
      has_many :rates, options
    end

    # Maximum value accepted when rating the model. Default is 5.
    #
    # Change it by passing the :stars option to +ajaxful_rateable+
    #
    #   ajaxful_rateable :stars => 10
    def max_rate_value
      options[:stars]
    end
  end

  # Instance methods for the rateable object.
  module InstanceMethods

    # Submits a new rate. Accepts a hash of tipical Ajax request.
    #
    # Example:
    #   # Articles Controller
    #   def rate
    #     @article = Article.find(params[:id])
    #     @article.rate(params[:stars], current_user)
    #     # some page update here ...
    #   end
    def rate(stars, user, dimension = nil)
      return false if (stars.to_i > self.class.max_rate_value)
      raise AlreadyRatedError if (!self.class.options[:allow_update] && rated_by?(user, dimension))

      rate = (self.class.options[:allow_update] && rated_by?(user, dimension)) ? rate_by(user, dimension) : rates.build
      rate.stars = stars
      rate.dimension = dimension

      if user.respond_to?(:rates)
        user.rates << rate
      else
        rate.send "#{self.class.user_class_name}_id=", user.id
      end if rate.new_record?
      rate.save!
      # self.update_cached_average
    end

    # Returns an array with all users that have rated this object.
    def raters
      eval(self.class.user_class_name.classify).find_by_sql(
        ["SELECT DISTINCT u.* FROM #{self.class.user_class_name.pluralize} u INNER JOIN rates r ON " +
            "u.[id] = r.[#{self.class.user_class_name}_id] WHERE r.[rateable_id] = ? AND r.[rateable_type] = ?",
          id, self.class.name]
      )
    end

    # Finds the rate made by the user if he/she has already voted.
    def rate_by(user, dimension = nil)
      if dimension
        Rate.find(:first, :conditions => ["rateable_id = ? AND rateable_type = ? AND dimension = ? AND #{self.class.user_class_name}_id = ?", self.id, self.class.name, dimension, user])
      else
        rates.send "find_by_#{self.class.user_class_name}_id", user
      end
    end

    # Return true if the user has rated the object, otherwise false
    def rated_by?(user, dimension = nil)
      !rate_by(user, dimension).nil?
    end

    # Instance's total rates.
    def total_rates(dimension = nil)
      if dimension
        # self.send("#{dimension}_rates").send 'count'
        Rate.count(:conditions => ["rateable_id = ? AND rateable_type = ? AND dimension = ?", self.id, self.class.name, dimension])
      else
        rates.count
      end
    end

    # Total sum of the rates.
    def rates_sum(dimension = nil)
      if dimension
        Rate.sum(:stars, :conditions => "rateable_id = '#{self.id}' AND rateable_type = '#{self.class.name}' AND dimension = '#{dimension}'")
        # self.send("#{dimension}_rates").send('sum', :stars)
      else
        rates.sum(:stars)
      end
    end

    # Rating average for the object.
    #
    # Pass false as param to force the calculation if you are caching it.
    def rate_average(cached = true, dimension = nil)
      # avg = if cached && self.class.caching_average?
      #   send(self.class.options[:cache_column]).to_f
      # else
      avg = self.rates_sum(dimension).to_f / self.total_rates(dimension).to_f
      # end
      avg.nan? ? 0.0 : avg
    end

    # Updates the cached average column in the rateable model.
    def update_cached_average
      if self.class.caching_average?
        send("#{self.class.options[:cache_column]}=", self.rate_average(false))
        save!
      end
    end
  end

  module SingletonMethods

    # Name of the class for the user model.
    def user_class_name
      @@user_class_name ||= Rate.column_names.find do |c|
        u = c.scan(/(\w+)_id$/).flatten.first
        break u if u && u != 'rateable'
      end
    end

    # Finds all rateable objects rated by the +user+.
    def find_rated_by(user)
      find_statement(:user_id, user.id)
    end

    # Finds all rateable objects rated with +stars+.
    def find_rated_with(stars)
      find_statement(:stars, stars)
    end

    # Finds the rateable object with the highest rate average.
    def find_most_popular
      all.sort_by(&:rate_average).last
    end

    # Finds the rateable object with the lowest rate average.
    def find_less_popular
      all.sort_by(&:rate_average).first
    end

    # Finds rateable objects by Rate's attribute.
    def find_statement(attr_name, attr_value)
      rateable = self.base_class.name
      sql = sanitize_sql(["SELECT DISTINCT r2.* FROM rates r1 INNER JOIN " +
            "#{rateable.constantize.table_name} r2 ON r1.rateable_id = r2.id " +
            "WHERE (r1.[rateable_type] = ? AND r1.[#{attr_name}] = ?)",
          rateable, attr_value])
      find_by_sql(sql)
    end

    # Indicates if the rateable model is able to cache the rate average.
    #
    # Include a column named +rating_average+ in your rateable model with
    # default null, as decimal:
    #
    #   t.decimal :rating_average, :precision => 3, :scale => 1, :default => 0
    #
    # To customize the name of the column specify the option <tt>:cache_column</tt> to ajaxful_rateable
    #
    #   ajaxful_rateable :cache_column => :my_custom_column
    #
    def caching_average?
      column_names.include?(options[:cache_column].to_s)
    end
  end
end
