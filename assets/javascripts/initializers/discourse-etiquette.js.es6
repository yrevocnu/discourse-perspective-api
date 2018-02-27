import { withPluginApi } from 'discourse/lib/plugin-api';
import Composer from 'discourse/models/composer';

function initialize(api) {
  api.modifyClass('model:composer', {
    etiquette_ignored: false,

    save(opts) {
      const result = this._super(opts);
      if (result) {
        return result.catch(error => {
          this.set('etiquette_ignored', true);
          if (error.startsWith("Etiquette check fails")) {
            throw "It looks like what you're about to post might be considered rude or disrespectful to others, and may be flagged for review. If you still want to continue posting, please try again."
          } else {
            throw error;
          }
        }).then(result => {
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
