import msal from '@azure/msal-node';
import express from 'express';
import open from 'open';
import dotenv from 'dotenv';
import {Command} from 'commander';

dotenv.config();

const clientId = process.env.AZURE_APP_CLIENT_ID;
const tenantId = process.env.AZURE_DIRECTORY_TENANT_ID;
const port = 3000;

const config = {
  auth: {
    clientId: clientId,
    authority: `https://login.microsoftonline.com/${tenantId}`,
    redirectUri: `http://localhost:${port}/auth/callback`,
  },
  system: {
    loggerOptions: {
      loggerCallback(loglevel, message, containsPii) {
        console.log(message);
      },
      piiLoggingEnabled: false,
      logLevel: msal.LogLevel.Info,
    },
  },
};

const pca = new msal.PublicClientApplication(config);
const app = express();
let server;

app.get('/auth/callback', async (req, res) => {
  const tokenRequest = {
    code: req.query.code,
    scopes: ['openid', 'profile', 'email'],
    redirectUri: `http://localhost:${port}/auth/callback`,
    codeVerifier: req.query.state,
  };

  try {
    const response = await pca.acquireTokenByCode(tokenRequest);
    console.log('Access token:', response.accessToken);
    res.send('Authentication successful! You can close the browser and check the console for your access token.');
    server.close();
  } catch (error) {
    console.error(error);
    res.status(500).send('Error during authentication.');
  }
});

async function loginCommand() {
  const authCodeUrlParameters = {
    scopes: ['openid', 'profile', 'email'],
    redirectUri: `http://localhost:${port}/auth/callback`,
    codeChallengeMethod: 'S256',
  };

  const authCodeUrlResponse = await pca.getAuthCodeUrl(authCodeUrlParameters);
  await open(authCodeUrlResponse);
}

const program = new Command();
program
  .command('login')
  .description('Authenticate the user and obtain an access token')
  .action(async () => {
    server = app.listen(port, async () => {
      console.log(`Server is listening on port ${port}`);
    });

    await loginCommand();
  });

program.parse(process.argv);