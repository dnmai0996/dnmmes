import {createHandler} from '../../server/accounts-service.mjs';
// Server-only. NEVER import this file into public/, and NEVER log credentials.
export default createHandler();
