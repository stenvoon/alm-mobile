# Base class for all models.
module.exports = Backbone.Model.extend
  idAttribute: 'ObjectID'

  parse: (resp) ->
    return resp if resp._ref?
    return (value for key, value of resp)[0] # Get value for only key
