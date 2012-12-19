DetailView = require('views/detail/detail_view')
template = require('./templates/user_story_detail')
UserStory = require 'models/user_story'
UserStoryCollection = require 'models/user_story_collection'

module.exports = DetailView.extend({
  modelType: UserStory
  id: 'user-story-detail-view'
  template: template
  fields: [
    'FormattedID',
    'Name',
    'Owner',
    'Tags',
    'Project',
    'Description',
    'Iteration',
    'Release',
    'ScheduleState',
    'PlanEstimate'
  ]
})