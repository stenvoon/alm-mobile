define ->
  jqueryBase64 = require 'jqueryBase64'
  appConfig = require 'appConfig'
  utils = require 'lib/utils'
  Model = require 'models/base/model'
  User = require 'models/user'
  Preference = require 'models/preference'
  UserStory = require 'models/user_story'
  UserProfile = require 'models/user_profile'
  Schema = require 'collections/schema'
  Iterations = require 'collections/iterations'
  Preferences = require 'collections/preferences'
  Projects = require 'collections/projects'
  Users = require 'collections/users'

  class Session extends Model
    initialize: (@clientMetricsParent, @aggregator) ->
      super
      @pagesize = 200
      @set
        securityToken: window.sessionStorage.getItem 'token'
      @listenTo this, 'change:user', @_onUserChange
      @listenTo this, 'change:mode', @_onModeChange
      @listenTo this, 'change:boardField', @_onBoardFieldChange
      @listenTo this, 'change:project', @_onProjectChange
      @listenTo this, 'change:iteration', @_onIterationChange

    authenticated: (cb) ->
      if !@get('securityToken')
        return cb? false

      @fetchUserInfo (err, model) =>
        cb? !err?

    authenticate: (username, password, cb) ->
      $.ajax(
        url: "#{appConfig.almWebServiceBaseUrl}/webservice/@@WSAPI_VERSION/security/authorize"
        type: 'GET'
        dataType: 'json'
        xhrFields:
          withCredentials: true
        beforeSend: (xhr) ->
          xhr.setRequestHeader("Authorization", """Basic #{$.base64.encode(username + ':' + password)}""")
          xhr.setRequestHeader("X-Requested-By", "Rally")
          xhr.setRequestHeader("X-RallyIntegrationName", appConfig.appName)
        success: (data, status, xhr) =>
          if data.OperationResult.Errors.length > 0
            return cb? false

          @setUsername username
          @setSecurityToken data.OperationResult.SecurityToken

          @fetchUserInfo (err, model) =>
            cb? !err?
        error: (xhr, errorType, error) =>
          cb? false
      )

    initSessionForUser: (options) ->
      @aggregator.beginLoad component: this, description: 'session init'
      projects = new Projects()
      projects.clientMetricsParent = this
      @set 'projects', projects

      preferences = new Preferences()
      preferences.clientMetricsParent = this
      @set 'prefs', preferences

      userProfile = new UserProfile
        ObjectID: utils.getOidFromRef(@get('user').get('UserProfile')._ref)
      userProfile.clientMetricsParent = this

      $.when(
        projects.fetch(
          data:
            fetch: 'Name,SchemaVersion'
            pagesize: @pagesize
            order: 'Name'
        ),
        userProfile.fetch()
        preferences.fetchMobilePrefs @get('user')
      ).then (p, u, prefs) =>
        @_setModeFromPreference()
        totalProjectResults = p[0].QueryResult.TotalResultCount
        @_fetchRestOfProjects(projects, totalProjectResults).then =>
          @_setDefaultProject projects, userProfile

    setIterationPreference: (value) ->
      projectRef = @get('project').get('_ref')
      prefs = @get('prefs')

      prefs.updateProjectPreference @get('user').get('_ref'), projectRef, Preference::defaultIteration, value

    getProjectName: ->
      try
        @get('project').get('_refObjectName')
      catch e
        ""

    isSelfMode: -> @get('mode') == 'self'
    isTeamMode: -> @get('mode') == 'team'

    setSecurityToken: (securityToken) ->
      @set 'securityToken', securityToken
      window.sessionStorage.setItem 'token', if securityToken then securityToken else ''

    getSecurityToken: ->
      @get 'securityToken'

    setUsername: (username) ->
      window.sessionStorage.setItem 'username', if username then username else ''

    getUsername: ->
      window.sessionStorage.getItem 'username'

    hasAcceptedLabsNotice: ->
      @get('prefs').findPreference(Preference::acceptedLabsNotice)?

    acceptLabsNotice: ->
      @aggregator.beginLoad component: this, description: 'accepting labs notics'
      $.when(
        @get('prefs').updatePreference @get('user'), Preference::acceptedLabsNotice, true
      )

    logout: (options = {}) ->
      @setSecurityToken null
      @setUsername null
      @clear silent: true

      @aggregator.beginLoad component: this, description: 'logging out'
      $.ajax(
        url: "#{appConfig.almWebServiceBaseUrl}/resources/jsp/security/clear.jsp"
        type: 'GET'
        dataType: 'html'
        beforeSend: (xhr) ->
          xhr.setRequestHeader("X-Requested-By", "Rally")
          xhr.setRequestHeader("X-RallyIntegrationName", appConfig.appName)
      ).always => @aggregator.endLoad component: this
          
    fetchUserInfo: (cb) ->
      user = new User()
      user.clientMetricsParent = this
      @aggregator.beginLoad component: this, description: 'fetching logged-in user'

      user.fetchSelf (err, u) =>
        @aggregator.endLoad component: this
        unless err?
          @set 'user', u
        cb(err, u)

    initColumnsFor: (boardField) ->
      pref = "#{Preference::defaultBoardColumnsPrefix}.#{boardField}"
      savedColumns = @get('prefs').findProjectPreference(@get('project').get('_ref'), pref)
      if savedColumns
        columns = savedColumns.get 'Value'

      visibleColumns = if columns then columns.split ',' else @_getDefaultBoardColumns(boardField)
      @setBoardColumns boardField, visibleColumns
      visibleColumns

    getBoardColumns: (boardField = @get('boardField')) ->
      pref = "#{Preference::defaultBoardColumnsPrefix}.#{boardField}"
      projectOid = utils.getOidFromRef @get('project').get('_ref')
      columns = @get "#{pref}.#{projectOid}"

      unless columns
        columns = @initColumnsFor boardField

      columns

    toggleBoardColumn: (column, boardField = @get('boardField')) ->
      shownColumns = @getBoardColumns boardField

      newColumns = if _.contains(shownColumns, column)
        _.without(shownColumns, column)
      else
        allowedValues = UserStory.getAllowedValues boardField
        columns = _.pluck(allowedValues, 'StringValue')

        _.intersection(columns, shownColumns.concat([column]))

      @setBoardColumns boardField, newColumns

    setBoardColumns: (boardField, columns) ->
      @aggregator.beginLoad component: this, description: 'saving board columns'
      pref = "#{Preference::defaultBoardColumnsPrefix}.#{boardField}"
      projectOid = utils.getOidFromRef @get('project').get('_ref')

      @set "#{pref}.#{projectOid}", columns
      @get('prefs').updateProjectPreference(
        @get('user').get('_ref'),
        @get('project').get('_ref'),
        pref,
        columns.join(',')
      ).always => @aggregator.endLoad component: this

    _getDefaultBoardColumns: (boardField) ->
      switch boardField
        when 'ScheduleState' then ['Defined', 'In-Progress', 'Completed', 'Accepted']

    _fetchRestOfProjects: (projects, totalCount) ->
      start = @pagesize + 1
      projectFetches = while totalCount >= start
        fetch = projects.fetch(
          remove: false
          data:
            fetch: 'Name,SchemaVersion'
            start: start
            pagesize: @pagesize
            order: 'Name'
        )
        start += @pagesize
        fetch

      $.when.apply($, projectFetches).always =>
        @aggregator.endLoad component: this

    _setDefaultProject: (projects, userProfile) ->
      defaultProject = @get('prefs').findPreference(Preference::defaultProject)
      if defaultProject
        savedProject = projects.find _.isAttributeEqual('_ref', defaultProject.get('Value'))
        @set('project', savedProject) if savedProject

      if !@get 'project'
        defaultProject = userProfile.get('DefaultProject')?._ref
        proj = projects.find _.isAttributeEqual('_ref', defaultProject)
        @set 'project', proj || projects.first()

    _setIterationFromPreference: ->
      iteration = null
      savedIteration = @get('prefs').findProjectPreference(@get('project').get('_ref'), Preference::defaultIteration)
      if savedIteration
        iteration = @get('iterations').find _.isAttributeEqual('_ref', savedIteration.get('Value'))

      @set('iteration', iteration)

    _setModeFromPreference: ->
      mode = 'team'
      savedMode = @get('prefs').findPreference Preference::defaultMode
      if savedMode
        mode = savedMode.get 'Value'

      @set 'mode', mode

    _setBoardFieldFromPreference: ->
      boardField = 'ScheduleState'
      savedBoardField = @get('prefs').findProjectPreference @get('project').get('_ref'), Preference::defaultBoardField
      if savedBoardField
        boardField = savedBoardField.get 'Value'

      @set 'boardField', boardField

    _loadSchema: (project) ->
      schema = new Schema()
      schema.clientMetricsParent = this
      schema.fetchForProject(project)

    _onModeChange: (model, value, options) ->
      @get('prefs').updatePreference @get('user'), Preference::defaultMode, value

    _onBoardFieldChange: (model, value, options) ->
      @get('prefs').updateProjectPreference @get('user').get('_ref'), @get('project').get('_ref'), Preference::defaultBoardField, value

    _onProjectChange: (model, value, options) ->
      @aggregator.beginLoad component: this, description: 'on project change'
      projectRef = value.get('_ref')
      prefs = @get('prefs')

      @_setBoardFieldFromPreference()

      prefs.updatePreference @get('user'), Preference::defaultProject, projectRef

      iterations = new Iterations()
      iterations.clientMetricsParent = this
      @set 'iterations', iterations

      $.when(
        @_loadSchema(value),
        iterations.fetch(
          data:
            fetch: 'Name,StartDate,EndDate'
            pagesize: @pagesize
            order: 'StartDate DESC,EndDate DESC,ObjectID'
            query: "(Project = \"#{projectRef}\")"
        )
      ).then (s, i) =>
        @initColumnsFor @get('boardField')
        @_setIterationFromPreference()
        @aggregator.endLoad component: this
        @publishEvent "projectready", @getProjectName()

    _onIterationChange: (model, value, options) ->
      iterationRef = value?.get('_ref')
      @setIterationPreference iterationRef

    _asClientMetricsParent: -> clientMetricsParent: this
