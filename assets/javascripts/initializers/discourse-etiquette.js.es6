import { withPluginApi } from 'discourse/lib/plugin-api';
import Composer from 'discourse/models/composer';
import { on, observes } from 'ember-addons/ember-computed-decorators';
import { renderSpinner } from 'discourse/helpers/loading-spinner';

function initialize(api) {
  api.modifyClass('controller:composer', {
    @observes('model.viewOpen', 'model.etiquette_ignored')
    _updateSavingStatus() {
      if (!this.get('model.viewOpen') && !this.get('model.etiquette_ignored')) {
        Ember.run.scheduleOnce('render', () => {
          $('.saving-text').html(I18n.t('etiquette.status') + renderSpinner('small'));
        });
      }
    },

    save(force) {
      if (this.get("disableSubmit")) return;

      // Clear the warning state if we're not showing the checkbox anymore
      if (!this.get('showWarning')) {
        this.set('model.isWarning', false);
      }

      const composer = this.get('model');

      if (composer.get('cantSubmitPost')) {
        this.set('lastValidatedAt', Date.now());
        return;
      }

      composer.set('disableDrafts', true);

      // for now handle a very narrow use case
      // if we are replying to a topic AND not on the topic pop the window up
      if (!force && composer.get('replyingToTopic')) {

        const currentTopic = this.get('topicModel');
        if (!currentTopic || currentTopic.get('id') !== composer.get('topic.id'))
        {
          const message = I18n.t("composer.posting_not_on_topic");

          let buttons = [{
            "label": I18n.t("composer.cancel"),
            "class": "d-modal-cancel",
            "link": true
          }];

          if (currentTopic) {
            buttons.push({
              "label": I18n.t("composer.reply_here") + "<br/><div class='topic-title overflow-ellipsis'>" + currentTopic.get('fancyTitle') + "</div>",
              "class": "btn btn-reply-here",
              callback: () => {
                composer.set('topic', currentTopic);
                composer.set('post', null);
                this.save(true);
              }
            });
          }

          buttons.push({
            "label": I18n.t("composer.reply_original") + "<br/><div class='topic-title overflow-ellipsis'>" + this.get('model.topic.fancyTitle') + "</div>",
            "class": "btn-primary btn-reply-on-original",
            callback: () => this.save(true)
          });

          bootbox.dialog(message, buttons, { "classes": "reply-where-modal" });
          return;
        }
      }

      var staged = false;

      // TODO: This should not happen in model
      const imageSizes = {};
      $('#reply-control .d-editor-preview img').each((i, e) => {
        const $img = $(e);
        const src = $img.prop('src');

        if (src && src.length) {
          imageSizes[src] = { width: $img.width(), height: $img.height() };
        }
      });

      const promise = composer.save({ imageSizes, editReason: this.get("editReason")}).then(result=> {
        if (result.responseJson.action === "enqueued") {
          this.send('postWasEnqueued', result.responseJson);
          this.destroyDraft();
          this.close();
          this.appEvents.trigger('post-stream:refresh');
          return result;
        }

        // If user "created a new topic/post" or "replied as a new topic" successfully, remove the draft.
        if (result.responseJson.action === "create_post" || this.get('replyAsNewTopicDraft') || this.get('replyAsNewPrivateMessageDraft')) {
          this.destroyDraft();
        }
        if (this.get('model.action') === 'edit') {
          this.appEvents.trigger('post-stream:refresh', { id: parseInt(result.responseJson.id) });
          if (result.responseJson.post.post_number === 1) {
            this.appEvents.trigger('header:update-topic', composer.get('topic'));
          }
        } else {
          this.appEvents.trigger('post-stream:refresh');
        }

        if (result.responseJson.action === "create_post") {
          this.appEvents.trigger('post:highlight', result.payload.post_number);
        }
        this.close();

        const currentUser = Discourse.User.current();
        if (composer.get('creatingTopic')) {
          currentUser.set('topic_count', currentUser.get('topic_count') + 1);
        } else {
          currentUser.set('reply_count', currentUser.get('reply_count') + 1);
        }

        const disableJumpReply = Discourse.User.currentProp('disable_jump_reply');
        if (!composer.get('replyingToTopic') || !disableJumpReply) {
          const post = result.target;
          if (post && !staged) {
            DiscourseURL.routeTo(post.get('url'));
          }
        }

      }).catch(this._cacthErrorOnSave.bind(this));

      if (this.get('application.currentRouteName').split('.')[0] === 'topic' &&
          composer.get('topic.id') === this.get('topicModel.id')) {
        staged = composer.get('stagedPost');
      }

      this.appEvents.trigger('post-stream:posted', staged);

      this.messageBus.pause();
      promise.finally(() => this.messageBus.resume());

      return promise;
    },

    _cacthErrorOnSave(error) {
      const composer = this.get('model');
      composer.set('disableDrafts', false);
      composer.set('etiquette_ignored', true);
      if (error.startsWith("[Etiquette]")) {
        const message = I18n.t("etiquette.etiquette_message");

        let buttons = [{
          "label": I18n.t("etiquette.composer_continue"),
          "class": "btn",
          callback: () => this.save(false)
        }, {
          "label": I18n.t("etiquette.composer_edit"),
          "class": "btn-primary"
        }];
        bootbox.dialog(message, buttons);
      } else {
        this.appEvents.one('composer:will-open', () => bootbox.alert(error));
      }
    },
  });

  api.modifyClass('model:composer', {
    etiquette_ignored: false,

    save(opts) {
      const result = this._super(opts);
      if (result) {
        return result.then(result => {
          // reset flag
          if (this.get('etiquette_ignored')) {
            this.set('etiquette_ignored', false);
          }
          return result;
        });
      }
    }
  });
}

export default {
  name: 'discourse-etiquette',

  initialize(container) {
    const siteSettings = container.lookup('site-settings:main');
    if (siteSettings.etiquette_enabled) {
      withPluginApi('0.8.17', initialize);
      Composer.serializeOnCreate('etiquette_ignored');
      Composer.serializeToTopic('etiquette_ignored', 'etiquette_ignored');
    }
  }
}
