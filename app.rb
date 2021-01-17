# frozen_string_literal: true

require 'sinatra'
require 'json'
require 'httparty'
require 'redis'
require 'dotenv'
require 'text'
require 'sanitize'
require 'humanize'

configure do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true

  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV['LOCAL_REDIS_URL'])
  when :production
    uri = URI.parse(ENV['REDISCLOUD_URL'])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

# Handles the POST request made by the Slack Outgoing webhook
# Params sent in the request:
#
# token=abc123
# team_id=T0001
# channel_id=C123456
# channel_name=test
# timestamp=1355517523.000005
# user_id=U123456
# user_name=Steve
# text=trebekbot jeopardy me
# trigger_word=trebekbot
#
post '/' do
  begin
    puts "[LOG] #{params}"
    params[:text] = params[:text].sub(params[:trigger_word], '').strip
    response = if params[:token] != ENV['OUTGOING_WEBHOOK_TOKEN']
                 'Invalid token'
               elsif channel_blacklisted?(params[:channel_name])
                 "Sorry, can't play in this channel."
               elsif params[:text].match(/^jeopard(y|ize) me/i)
                 respond_with_question(params)
               elsif params[:text].match(/^reset my score$/i)
                 respond_with_reset_score
               elsif params[:text].match(/my score$/i)
                 respond_with_user_score(params[:user_id])
               elsif params[:text].match(/^help$/i)
                 respond_with_help
               elsif params[:text].match(/^(show\s+)?(me\s+)?(the\s+)?leaderboard$/i)
                 respond_with_leaderboard
               elsif params[:text].match(/^(show\s+)?(me\s+)?(the\s+)?loserboard$/i)
                 respond_with_loserboard
               elsif params[:text].match(/^show (me\s+)?(the\s+)?categories$/i)
                 respond_with_categories
               elsif (matches = params[:text].match(/^I.ll take (.*)/i))
                 respond_with_question(params, matches[1])
               elsif (matches = params[:text].match(/^Give me (.*)/i))
                 respond_with_question(params, matches[1])
               elsif (matches = params[:text].match(/debug (.*)/i))
                 respond_with_debug_question(params, matches[1])
               else
                 process_answer(params)
               end
  rescue StandardError => e
    puts "[ERROR] #{e}"
    response = ''
  end
  status 200
  body json_response_for_slack(response)
end

# Puts together the json payload that needs to be sent back to Slack
#
def json_response_for_slack(reply)
  response = { text: reply, link_names: 1 }
  response[:username] = ENV['BOT_USERNAME'] unless ENV['BOT_USERNAME'].nil?
  response[:icon_emoji] = ENV['BOT_ICON'] unless ENV['BOT_ICON'].nil?
  response.to_json
end

# Determines if a game of Jeopardy is allowed in the given channel
#
def channel_blacklisted?(channel_name)
  !ENV['CHANNEL_BLACKLIST'].nil? && ENV['CHANNEL_BLACKLIST'].split(',').find do |a|
    a.gsub('#', '').strip == channel_name
  end
end

# Puts together the response to a request to start a new round (`jeopardy me`):
# If the bot has been "shushed", says nothing.
# Otherwise, speaks the answer to the previous round (if any),
# speaks the category, value, and the new question, and shushes the bot for 5 seconds
# (this is so two or more users can't do `jeopardy me` within 5 seconds of each other.)
#
def respond_with_question(params, category = nil)
  channel_id = params[:channel_id]
  question = ''
  unless $redis.exists?("shush:question:#{channel_id}")
    response = get_question category
    key = "current_question:#{channel_id}"
    previous_question = $redis.get(key)
    unless previous_question.nil?
      previous_question = JSON.parse(previous_question)['answer']
      question = "The answer is `#{previous_question}`.\n"
    end
    question += "The category is `#{response['category']['title']}` for #{currency_format(response['value'])}: `#{response['question']}`"
    puts "[LOG] ID: #{response['id']} | Category: #{response['category']['title']} | Question: #{response['question']} | Answer: #{response['answer']} | Value: #{response['value']}"
    $redis.pipelined do
      $redis.set(key, response.to_json)
      $redis.setex("shush:question:#{channel_id}", 10, 'true')
      $redis.set("category:#{response['category']['title']}", response['category'].to_json.to_s)
    end
  end
  question
end

# For debugging. Question value is 0, but categories can be specified.
# Puts together the response to a request to start a new round (`jeopardy me`):
# If the bot has been "shushed", says nothing.
# Otherwise, speaks the answer to the previous round (if any),
# speaks the category, value, and the new question, and shushes the bot for 5 seconds
# (this is so two or more users can't do `jeopardy me` within 5 seconds of each other.)
#
def respond_with_debug_question(params, category = nil)
  channel_id = params[:channel_id]
  question = ''
  unless $redis.exists?("shush:question:#{channel_id}")
    response = get_debug_question category
    key = "current_question:#{channel_id}"
    previous_question = $redis.get(key)
    unless previous_question.nil?
      previous_question = JSON.parse(previous_question)['answer']
      question = "The answer is `#{previous_question}`.\n"
    end
    question += "The category is `#{response['category']['title']}` for #{currency_format(response['value'])}: `#{response['question']}`"
    puts "[LOG] ID: #{response['id']} | Category: #{response['category']['title']} | Question: #{response['question']} | Answer: #{response['answer']} | Value: #{response['value']}"
    $redis.pipelined do
      $redis.set(key, response.to_json)
      $redis.setex("shush:question:#{channel_id}", 10, 'true')
      $redis.set("category:#{response['category']['title']}", response['category'].to_json.to_s)
    end
  end
  question
end

# Gets a random answer from the jService API, and does some cleanup on it:
# If the question is not present, requests another one
# If the question contains a blacklisted substring, request another one
# If the answer doesn't have a value, sets a default of $200
# If there's HTML in the answer, sanitizes it (otherwise it won't match the user answer)
# Adds an "expiration" value, which is the timestamp of the Slack request + the seconds to answer config var
#
def get_question(category_key = nil)
  if !category_key.nil? && (data = $redis.get("category:#{category_key}"))
    category = JSON.parse(data)
    offset = rand(category['clues_count'])
    uri = "http://jservice.io/api/clues?category=#{category['id']}&offset=#{offset}"
  else
    uri = 'http://jservice.io/api/random?count=1'
  end
  puts "[LOG] #{uri}"
  request = HTTParty.get(uri)
  puts "[LOG] #{request.body}"
  response = JSON.parse(request.body).first
  question = response['question']
  if question.nil? || question.strip == '' || ENV['QUESTION_SUBSTRING_BLACKLIST'].split(',').any? do |phrase|
       question.downcase.include?(phrase.downcase)
     end
    response = get_question
    # response = get_question(category_key)
  end
  response['value'] = 200 if response['value'].nil?
  response['answer'] = Sanitize.fragment(response['answer'].gsub(/\s+(&nbsp;|&)\s+/i, ' and '))
  response['expiration'] = params['timestamp'].to_f + ENV['SECONDS_TO_ANSWER'].to_f
  response
end

# For debugging. Gets a question from a category, ignoring current category list. (value is 0)
# Gets a random answer from the jService API, and does some cleanup on it:
# If the question is not present, requests another one
# If the question contains a blacklisted substring, request another one
# If the answer doesn't have a value, sets a default of $200
# If there's HTML in the answer, sanitizes it (otherwise it won't match the user answer)
# Adds an "expiration" value, which is the timestamp of the Slack request + the seconds to answer config var
#
def get_debug_question(category_key = nil)
  if !category_key.nil?
    category = JSON.parse(data)
    offset = rand(category['clues_count'])
    uri = "http://jservice.io/api/clues?category=#{category['id']}&offset=#{offset}"
  else
    uri = 'http://jservice.io/api/random?count=1'
  end
  puts "[LOG] #{uri}"
  request = HTTParty.get(uri)
  puts "[LOG] #{request.body}"
  response = JSON.parse(request.body).first
  question = response['question']
  if question.nil? || question.strip == '' || ENV['QUESTION_SUBSTRING_BLACKLIST'].split(',').any? do |phrase|
       question.downcase.include?(phrase.downcase)
     end
    response = get_debug_question
    # response = get_debug_question(category_key)
  end
  response['value'] = 0
  response['answer'] = Sanitize.fragment(response['answer'].gsub(/\s+(&nbsp;|&)\s+/i, ' and '))
  response['expiration'] = params['timestamp'].to_f + ENV['SECONDS_TO_ANSWER'].to_f
  response
end

# Puts together the response to a request for categories:
#
def respond_with_categories
  max_category = 18_418
  uri = "http://jservice.io/api/categories?count=5&offset=#{1 + rand(max_category / 5)}"
  request = HTTParty.get(uri)
  puts "[LOG] #{request.body}"

  category_titles = []
  data = JSON.parse(request.body)
  data.each do |child|
    category_titles << child['title']
    key = "category:#{child['title']}"
    $redis.set(key, child.to_json)
  end
  response = "Wonderful. Let's take a look at the categories. They are: `"
  response += "#{category_titles.join('`, `')}`."
  response
end

# Processes an answer submitted by a user in response to a Jeopardy round:
# If there's no round, returns a funny SNL Trebek quote.
# Otherwise, responds appropriately if:
# The user already tried to answer;
# The time to answer the round is up;
# The answer is correct and in the form of a question;
# The answer is correct and not in the form of a question;
# The answer is incorrect.
# Update the score and marks the round as answer, depending on the case.
#
def process_answer(params)
  channel_id = params[:channel_id]
  user_id = params[:user_id]
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  reply = ''
  if current_question.nil?
    reply = trebek_me unless $redis.exists?("shush:answer:#{channel_id}")
  else
    current_question = JSON.parse(current_question)
    current_answer = current_question['answer']
    h_current_answer = humanize_numbers(current_answer)
    user_answer = params[:text]
    h_user_answer = humanize_numbers(user_answer)
    answered_key = "user_answer:#{channel_id}:#{current_question['id']}:#{user_id}"
    if $redis.exists?(answered_key)
      reply = "You had your chance, #{get_slack_name(user_id)}. Let someone else answer."
    elsif params['timestamp'].to_f > current_question['expiration']
      if correct_answer?(h_current_answer, h_user_answer)
        is_exact = exactly_correct_answer?(h_current_answer, h_user_answer)
        reply = "#{is_exact ? 'That is correct' : 'We would have accepted that'}, #{get_slack_name(user_id)}, but time's up! #{is_exact ? '' : "The full answer we were looking for is `#{current_answer}`. "}Remember, you have #{ENV['SECONDS_TO_ANSWER']} seconds to answer."
      else
        reply = "Time's up, #{get_slack_name(user_id)}! Remember, you have #{ENV['SECONDS_TO_ANSWER']} seconds to answer. The correct answer was `#{current_answer}`."
      end
      mark_question_as_answered(params[:channel_id])
    elsif question_format?(h_user_answer) && correct_answer?(h_current_answer, h_user_answer)
      is_exact = exactly_correct_answer?(h_current_answer, h_user_answer)
      score = update_score(user_id, current_question['value'])
      reply = "#{is_exact ? 'That is correct' : "We'll accept that"}, #{get_slack_name(user_id)}. #{is_exact ? '' : "The full answer we were looking for is `#{current_answer}`. "}Your total score is #{currency_format(score)}."
      mark_question_as_answered(params[:channel_id])
    elsif correct_answer?(h_current_answer, h_user_answer)
      is_exact = exactly_correct_answer?(h_current_answer, h_user_answer)
      score = update_score(user_id, (current_question['value'] * -1))
      reply = "#{is_exact ? 'That is correct' : 'We would have accepted that'}, #{get_slack_name(user_id)}, but responses have to be in the form of a question. Your total score is #{currency_format(score)}."
      $redis.setex(answered_key, ENV['SECONDS_TO_ANSWER'], 'true')
    else
      score = update_score(user_id, (current_question['value'] * -1))
      reply = "That is incorrect, #{get_slack_name(user_id)}. Your score is now #{currency_format(score)}."
      $redis.setex(answered_key, ENV['SECONDS_TO_ANSWER'], 'true')
    end
  end
  reply
end

# Checks if a word is actually a numeral
#
def regex_is_number?(string)
  no_commas = string.gsub(',', '')
  matches = no_commas.match(/-?\d+(?:\.\d+)?/)
  if !matches.nil? && matches.size == 1 && matches[0] == no_commas
    true
  else
    false
  end
end

# Converts all numerals in a string to humanized words
# For example, `Top 40` becomes `Top forty`
#
def humanize_numbers(raw_string)
  arr = raw_string.split
  arr.each_with_index do |word, index|
    next unless regex_is_number?(word)

    arr[index] = if word.include? '.'
                   word.delete(',').to_f.humanize
                 else
                   word.delete(',').to_i.humanize
                 end
    puts word
    puts arr[index]
  end
  arr.join(' ')
end

# Formats a number as currency.
# For example -10000 becomes -$10,000
#
def currency_format(number, currency = '$')
  prefix = number >= 0 ? currency : "-#{currency}"
  moneys = number.abs.to_s
  moneys.to_s.gsub!(/(\d+)(\d\d\d)/, '\\1,\\2') while moneys.match(/(\d+)(\d\d\d)/)
  "#{prefix}#{moneys}"
end

# Checks if the respose is in the form of a question:
# Removes punctuation and check if it begins with what/where/who
# (I don't care if there's no question mark)
#
def question_format?(answer)
  answer.gsub(/[^\w\s]/i, '').match(question_words)
end

# Checks if the user answer matches the correct answer.
# Does processing on both to make matching easier:
# Replaces "&" with "and";
# Removes punctuation;
# Removes question elements ("what is a")
# Strips leading/trailing whitespace and downcases.
# Finally, if the match is not exact, uses White similarity algorithm for "fuzzy" matching,
# to account for typos, etc.
# Checks the sanitized correct, the correct with parentheticals removed, and only the parentheticals
# e.g.
# "The Pope (Benedict XVI)" checks answer against "pope benedict xvi" and "pope" and "benedict xvi"
#
def correct_answer?(correct, answer)
  correct = correct.gsub(/^(the|a|an) /i, '')
                   .strip
                   .downcase

  correct_no_parenthetical = correct.gsub(/\(.*\)/, '').gsub(/[^\w\s]/i, '').strip
  correct_only_parenthetical = correct[/.*\(([^)]*)\)/, 1].gsub(/[^\w\s]/i, '').strip
  correct_only_parenthetical_deacronymed = correct_only_parenthetical.gsub(/\./, '').strip
  correct_sanitized = correct.gsub(/[^\w\s]/i, '').strip

  answer = answer
           .gsub(/\s+(&nbsp;|&)\s+/i, ' and ')
           .gsub(/[^\w\s]/i, '')
           .gsub(question_words, '')
           .gsub(/^(is|are|was|were) /, '')
           .gsub(/^(the|a|an) /i, '')
           .gsub(/\?+$/, '')
           .strip
           .downcase

  [correct_sanitized, correct_no_parenthetical, correct_only_parenthetical, correct_only_parenthetical_deacronymed].each do |solution|
    white = Text::WhiteSimilarity.new
    similarity = white.similarity(solution, answer)
    puts "[LOG] Correct answer: #{solution} | User answer: #{answer} | Similarity: #{similarity}"
    return true if solution == answer || similarity >= ENV['SIMILARITY_THRESHOLD'].to_f
  end
  false
end

# Like correct_answer? but only checks for exact matches for the purposes of copy changes
#
def exactly_correct_answer?(correct, answer)
  correct = correct.gsub(/[^\w\s]/i, '')
                   .gsub(/^(the|a|an) /i, '')
                   .strip
                   .downcase
  answer = answer
           .gsub(/\s+(&nbsp;|&)\s+/i, ' and ')
           .gsub(/[^\w\s]/i, '')
           .gsub(question_words, '')
           .gsub(/^(is|are|was|were) /, '')
           .gsub(/^(the|a|an) /i, '')
           .gsub(/\?+$/, '')
           .strip
           .downcase
  correct == answer
end

def question_words
  /^(what|whats|where|wheres|who|whos|when|whens|why|whys|how|hows) /i
end

# Marks question as answered by:
# Deleting the current question from redis,
# and "shushing" the bot for 5 seconds, so if two users
# answer at the same time, the second one won't trigger
# a response from the bot.
#
def mark_question_as_answered(channel_id)
  $redis.pipelined do
    $redis.del("current_question:#{channel_id}")
    $redis.del("shush:question:#{channel_id}")
    $redis.setex("shush:answer:#{channel_id}", 5, 'true')
  end
end

# Returns the given user's score.
#
def respond_with_user_score(user_id)
  user_score = get_user_score(user_id)
  "#{get_slack_name(user_id)}, your score is #{currency_format(user_score)}."
end

# Resets the requesting user's score to 0
#
def respond_with_reset_score
  user_id = params[:user_id]
  user_name = get_slack_name(user_id, { use_real_name: true })
  old_score = get_user_score(user_id)
  key = "user_score:#{user_id}"
  $redis.set(key, 0)

  "#{user_name}, your score was #{currency_format(old_score)}, and is now reset to #{currency_format(0)}"
end

# Gets the given user's score from redis
#
def get_user_score(user_id)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, 0)
    user_score = 0
  end
  user_score.to_i
end

# Updates the given user's score in redis.
# If the user doesn't have a score, initializes it at zero.
#
def update_score(user_id, score = 0)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, score)
    score
  else
    new_score = user_score.to_i + score
    $redis.set(key, new_score)
    new_score
  end
end

# Gets the given user's name(s) from redis.
# If it's not in redis, makes an API request to Slack to get it,
# and caches it in redis for a month.
#
# Options:
# use_real_name => returns the users full name instead of just the first name
#
def get_slack_name(user_id, options = {})
  options = { use_real_name: false }.merge(options)
  key = "slack_user_names:2:#{user_id}"
  names = $redis.get(key)
  if names.nil?
    names = get_slack_names_hash(user_id)
    $redis.setex(key, 60 * 60 * 24 * 30, names.to_json)
  else
    names = JSON.parse(names)
  end
  if options[:use_real_name]
    names['real_name'].nil? ? names['name'] : names['real_name']
  else
    names['first_name'].nil? ? names['name'] : names['first_name']
  end
end

# Makes an API request to Slack to get a user's set of names.
# (Slack's outgoing webhooks only send the user ID, so we need this to
# make the bot reply using the user's actual name.)
#
def get_slack_names_hash(user_id)
  uri = "https://slack.com/api/users.list?token=#{ENV['API_TOKEN']}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response['ok']
    user = response['members'].find { |u| u['id'] == user_id }
    names = { id: user_id, name: user['name'] }
    unless user['profile'].nil?
      unless user['profile']['real_name'].nil? || user['profile']['real_name'] == ''
        names['real_name'] =
          user['profile']['real_name']
      end
      unless user['profile']['first_name'].nil? || user['profile']['first_name'] == ''
        names['first_name'] =
          user['profile']['first_name']
      end
      unless user['profile']['last_name'].nil? || user['profile']['last_name'] == ''
        names['last_name'] =
          user['profile']['last_name']
      end
    end
  else
    names = { id: user_id, name: 'Sean Connery' }
  end
  names
end

# Speaks the top scores across Slack.
# The response is cached for 5 minutes.
#
def respond_with_leaderboard
  key = 'leaderboard:1'
  response = $redis.get(key)
  if response.nil?
    leaders = []
    get_score_leaders.each_with_index do |leader, i|
      user_id = leader[:user_id]
      name = get_slack_name(leader[:user_id], { use_real_name: true })
      score = currency_format(get_user_score(user_id))
      leaders << "#{i + 1}. #{name}: #{score}"
    end
    response = if !leaders.empty?
                 "Let's take a look at the top scores:\n\n#{leaders.join("\n")}"
               else
                 'There are no scores yet!'
               end
    $redis.setex(key, 60 * 5, response)
  end
  response
end

# Speaks the bottom scores across Slack.
# The response is cached for 5 minutes.
#
def respond_with_loserboard
  key = 'loserboard:1'
  response = $redis.get(key)
  if response.nil?
    leaders = []
    get_score_leaders({ order: 'asc' }).each_with_index do |leader, i|
      user_id = leader[:user_id]
      name = get_slack_name(leader[:user_id], { use_real_name: true })
      score = currency_format(get_user_score(user_id))
      leaders << "#{i + 1}. #{name}: #{score}"
    end
    response = if !leaders.empty?
                 "Let's take a look at the bottom scores:\n\n#{leaders.join("\n")}"
               else
                 'There are no scores yet!'
               end
    $redis.setex(key, 60 * 5, response)
  end
  response
end

# Gets N scores from redis, with optional sorting.
#
def get_score_leaders(options = {})
  options = { limit: 10, order: 'desc' }.merge(options)
  leaders = []
  $redis.scan_each(match: 'user_score:*') do |key|
    user_id = key.gsub('user_score:', '')
    leaders << { user_id: user_id, score: get_user_score(user_id) }
  end
  puts "[LOG] Leaderboard: #{leaders}"
  if leaders.size > 1
    leaders = if options[:order] == 'desc'
                leaders.uniq { |l| l[:user_id] }.sort { |a, b| b[:score] <=> a[:score] }.slice(0, options[:limit])
              else
                leaders.uniq { |l| l[:user_id] }.sort { |a, b| a[:score] <=> b[:score] }.slice(0, options[:limit])
              end
  else
    leaders
  end
end

# Funny quotes from SNL's Celebrity Jeopardy, to speak
# when someone invokes trebekbot and there's no active round.
#
def trebek_me
  ["Welcome back to Slack Jeopardy. Before we begin this Jeopardy round, I'd like to ask our contestants once again to please refrain from using ethnic slurs.",
   'Okay, Turd Ferguson.',
   'I hate my job.',
   "Let's just get this over with.",
   'Do you have an answer?',
   "I don't believe this. Where did you get that magic marker? We frisked you on the way in here.",
   'What a ride it has been, but boy, oh boy, these Slack users did not know the right answers to any of the questions.',
   "Back off. I don't have to take that from you.",
   'That is _awful_.',
   "Okay, for the sake of tradition, let's take a look at the answers.",
   'Beautiful. Just beautiful.',
   "Good for you. Well, as always, three perfectly good charities have been deprived of money, here on Slack Jeopardy. I'm #{ENV['BOT_USERNAME']}, and all of you should be ashamed of yourselves! Good night!",
   "And welcome back to Slack Jeopardy. Because of what just happened before during the commercial, I'd like to apologize to all blind people and children.",
   'Thank you, thank you. Moving on.',
   'I really thought that was going to work.',
   "Wonderful. Let's take a look at the categories. They are: `Potent Potables`, `Point to your own head`, `Letters or Numbers`, `Will this hurt if you put it in your mouth`, `An album cover`, `Make any noise`, and finally, `Famous Muppet Frogs`. I should add that the answer to every question in that category is `Kermit`.",
   'For the last time, that is not a category.',
   'Unbelievable.',
   "Great. Let's take a look at the final board. And the categories are: `Potent Potables`, `Sharp Things`, `Movies That Start with the Word Jaws`, `A Petit Déjeuner` -- that category is about French phrases, so let's just skip it.",
   "Enough. Let's just get this over with. Here are the categories, they are: `Potent Potables`, `Countries Between Mexico and Canada`, `Members of Simon and Garfunkel`, `I Have a Chardonnay` -- you choose this category, you automatically get the points and I get to have a glass of wine -- `Things You Do With a Pencil Sharpener`, `Tie Your Shoe`, and finally, `Toast`.",
   "Better luck to all of you, in the next round. It's time for Slack Jeopardy, let's take a look at the board. And the categories are: `Potent Potables`, `Literature` -- which is just a big word for books -- `Therapists`, `Current U.S. Presidents`, `Show and Tell`, `Household Objects`, and finally, `One-Letter Words`.",
   'Uh, I see. Get back to your podium.',
   "You look pretty sure of yourself. Think you've got the right answer?",
   "Welcome back to Slack Jeopardy. We've got a real barnburner on our hands here.",
   "And welcome back to Slack Jeopardy. I'd like to once again remind our contestants that there are proper bathroom facilities located in the studio.",
   "Welcome back to Slack Jeopardy. Once again, I'm going to recommend that our viewers watch something else.",
   "Great. Better luck to all of you in the next round. It's time for Slack Jeopardy. Let's take a look at the board. And the categories are: `Potent Potables`, `The Vowels`, `Presidents Who Are On the One Dollar Bill`, `Famous Titles`, `Ponies`, `The Number 10`, and finally: `Foods That End In \"Amburger\"`.",
   "Let's take a look at the board. The categories are: `Potent Potables`, `The Pen is Mightier` -- that category is all about quotes from famous authors, so you'll all probably be more comfortable with our next category -- `Shiny Objects`, continuing with `Opposites`, `Things you Shouldn't Put in Your Mouth`, `What Time is It?`, and, finally, `Months That Start With Feb`."].sample
end

# Shows the help text.
# If you add a new command, make sure to add some help text for it here.
#
def respond_with_help
  <<~HELP
    Type `#{ENV['BOT_USERNAME']} help` to see this helpful response. Good job!
    Type `#{ENV['BOT_USERNAME']} jeopardy me` to start a new round of Slack Jeopardy. I will pick the category and price. Anyone in the channel can respond.
    Type `#{ENV['BOT_USERNAME']} [what|where|who|when] [is|are] [answer]?` to respond to the active round. You have #{ENV['SECONDS_TO_ANSWER']} seconds to answer. Remember, responses must be in the form of a question, e.g. `#{ENV['BOT_USERNAME']} what is dirt?`.
    Type `#{ENV['BOT_USERNAME']} show the categories` to see a list of 5 categories to choose.
    Type `#{ENV['BOT_USERNAME']} I'll take [category]` start a new round with a specific category. I will pick the price.
    Type `#{ENV['BOT_USERNAME']} what is my score` to see your current score.
    Type `#{ENV['BOT_USERNAME']} reset my score` to reset your score and start over.
    Type `#{ENV['BOT_USERNAME']} show the leaderboard` to see the top scores.
    Type `#{ENV['BOT_USERNAME']} show the loserboard` to see the bottom scores.
  HELP
end
