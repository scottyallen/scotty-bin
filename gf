#!/usr/bin/env ruby

# Parses the output of git status, and returns the names of files that match your query expression.
# You can use this script to pipe the name of files in your checkout into other tools. Examples:
# gc `gf .flexlibproperties`  # restores all files that match fliexlibproperties
# mate `gf unmerged`          # Open all unmerged files in an editor
#
# Usage:
#   gf text
# which returns "abc/com/yahoo/api/controls/text.mxml" when the output of git status looks like:
#   modified:   abc/text.mxml
#   modified:   abc/form.mxml
#
# You can use many query terms after gf, and all lines that match any of them will be returned,
# separated by spaces.
#
# Add -n to have the files in the output separated by newlines instead of spaces.


#
# The output from git status looks like this:
#
# On branch adsets
# Changed but not updated:
#   (use "git add <file>..." to update what will be committed)
#
#       modified:   api/controls/text.mxml
#       modified:   api/controls/account/adsets/form.mxml
#
# Untracked files:
#   (use "git add <file>..." to include in what will be committed)
#
#     ...........

lines = `git status`.split("\n")
is_file = /^#\t/
files = []


# Removes "modified" etc. from the beginning of the line
def strip(line)
  line.gsub(/^#\s+(deleted|modified|new file|unmerged|typechange)?:?\s*/, "")
end

ARGV.each do |search_term|
  # ignore options
  next if search_term.index("-") == 0

  search = /#{search_term.gsub(".", "\\.")}/i
  lines.each do |line|
    next unless line.match(is_file)
    if search.match(line.downcase)
      files.push(strip(line))
    end
  end
end

files.uniq!

separator = ARGV.index("-n") ? "\n" : " "
# Escape any spaces in the paths by replacing them with question marks.
# Old school file globbing hack by Darrell!
files = files.map { |filename| filename.gsub(" ", "?" ) }

puts files.join(separator)