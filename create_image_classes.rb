#! /usr/bin/ruby

tabs = ["overview",
        "content",
        "exchange",
        "analytics",
        "account"]

states = ["normal",
          "over",
          "on"]

package = "com.ooyala.cms.assets"

tabs.each do
  |name|
  states.each do
    |state|
    class_name = "#{name.capitalize}Tab#{state.capitalize}"
    File.open("#{class_name}.as", 'w') do
      |f|
      f.write(<<-END)
package #{package}
{
  import mx.core.BitmapAsset;

  [Embed("images/tabs/#{name}_#{state}.png")]
  public class #{name.capitalize}Tab#{state.capitalize} extends BitmapAsset
  {
  }
}
      END
    end
  end
end
