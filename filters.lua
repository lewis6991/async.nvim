local inspect = require'inspect'
return {
   filter = function (t)
      for _, mod in ipairs(t) do
         print(inspect(mod))
      end
   end
}
