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
      store.set(LAST_CHECKED_POST_ID_KEY, val)
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
      success_checks = 0
      unless queued_post.empty?
        queued = Set.new(queued_post)
        checked = Set.new

        queued_post.each do |p|
          p "checking failed #{p}"
          p = Post.includes(:topic).find_by(id: p)
          if p.nil?
            checked.add(p.id)
            next
          end

          if DiscourseEtiquette.should_check_post?(p)
            begin
              DiscourseEtiquette.backfill_post_etiquette_check(p)
              checked.add(p.id)
            rescue e
              print(e)
              next
            end
          else
            checked.add(p.id)
          end
        end

        success_checks = checked.size
        store.set(FAILED_POST_ID_KEY, (Set.new(failed_post_ids[batch_size..-1]) + queued - checked).to_a)
      end

      return batch_size - success_checks
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
          rescue
            next
          end
        end
      end

      p "Last ID #{last_id}"
      p last_checked_post_id
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
      last_checked_post_timestamp + SiteSetting.etiquette_historical_inspection_period > DateTime.now &&
        last_id >= Post.order(id: :asc).pluck(:id).last
    end

    def start_new_iteration
      set_last_checked_post_id(0)
    end
  end
end
