-- The public API is added in the next implementation task. Loading the module
-- early lets plugins inspect their process-local session during startup.
return { session = require("sprite.session") }
