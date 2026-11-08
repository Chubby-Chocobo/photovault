'use strict';

// The block derivation is shared with the session hook, so it lives in hooks/lib (shared logic never flows from a skill into a hook)
module.exports = require('../../../../hooks/lib/workspace-ignore-blocks.cjs');
