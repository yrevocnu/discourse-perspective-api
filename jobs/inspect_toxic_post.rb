module Jobs
  class InspectToxicPost < Jobs::Scheduled
    every 10.minutes

    BATCH_SIZE = 1000
    LAST_CHECKED_POST_ID_KEY = 'last_checked_post_id'
    LAST_CHECKED_TIME_KEY = 'last_checked_iteration_timestamp'
    FAILED_POST_ID_KEY = 'failed_post_ids'

    def store
      @store ||= PluginStore.new('discourse-etiquette')
    end

    def last_checked_post_id
      @last_checked_post_id ||= store.get(LAST_CHECKED_POST_ID_KEY)&.to_i || 0
    end

    def set_last_checked_post_id(val)
      val = val.to_i
      store.set(LAST_CHECKED_TIME_KEY, DateTime.now)
      p store.set(LAST_CHECKED_POST_ID_KEY, val)
      @last_checked_post_id = val
    end

    def last_checked_post_timestamp
      @last_checked_post_timestamp ||= store.get(LAST_CHECKED_TIME_KEY)&.to_datetime || 100.years.ago
    end

    def previous_failed_post_ids
      @previous_failed_post_ids ||= store.get(FAILED_POST_ID_KEY) || []
    end

    def set_previous_failed_post_ids(val)
      list = val.to_a
      store.set(FAILED_POST_ID_KEY, list)
      @previous_failed_post_ids = list
    end

    def execute(args)
      return unless SiteSetting.etiquette_enabled? && SiteSetting.etiquette_backfill_posts

      p "retry"
      batch_size = retry_failed_checks(BATCH_SIZE)
      p "check"
      check_posts(batch_size)
    end

    def retry_failed_checks(batch_size)
      return if batch_size <= 0
      failed_post_ids = previous_failed_post_ids

      queued_post = failed_post_ids[0...batch_size]
      p "Queued_post: #{queued_post}"
      unless queued_post.empty?
        queued_post.each do |post_id|
          p "checking failed #{post_id}"
          post = Post.with_deleted.includes(:topic).find_by(id: post_id)
          next unless post
          puts "#{post_id} proceed passed the next?" if post.nil?

          if DiscourseEtiquette.should_check_post?(post)
            begin
              DiscourseEtiquette.backfill_post_etiquette_check(post)
            rescue => error
              Rails.logger.warn(error)
              next
            end
          end
        end
      end
      puts "Updating failed list: #{failed_post_ids[batch_size..-1].to_a}"
      p store.set(FAILED_POST_ID_KEY, failed_post_ids[batch_size..-1].to_a)

      return batch_size - queued_post.size
    end

    def check_posts(batch_size)
      return if batch_size <= 0
      queued = Set.new
      checked = Set.new
      last_id = last_checked_post_id
      Post.with_deleted.order(id: :asc).includes(:topic).offset(last_checked_post_id).limit(batch_size).find_each do |p|
        p "checking #{p.id}"
        queued.add(p.id)
        last_id = p.id
        if DiscourseEtiquette.should_check_post?(p)
          begin
            DiscourseEtiquette.backfill_post_etiquette_check(p)
            checked.add(p.id)
          rescue => error
            Rails.logger.info(error)
            next
          end
        end
      end

      p "Setting last ID #{last_id}"
      set_last_checked_post_id(last_id)
      p last_checked_post_id
      failed_post_ids = (queued - checked)
      unless failed_post_ids.empty?
        failed_post_ids = failed_post_ids + Set.new(previous_failed_post_ids)
        set_previous_failed_post_ids(failed_post_ids)
      end

      start_new_iteration if can_start_next_iteration?(last_id)
    end

    def can_start_next_iteration?(last_id)
      DateTime.now >= last_checked_post_timestamp + SiteSetting.etiquette_historical_inspection_period &&
        last_id >= Post.order(id: :asc).pluck(:id).last
    end

    def start_new_iteration
      set_last_checked_post_id(0)
    end
  end
end
