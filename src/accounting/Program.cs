// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

using Accounting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenFeature;
using OpenFeature.Contrib.Providers.Flagd;

Console.WriteLine("Accounting service started");

Environment.GetEnvironmentVariables()
    .FilterRelevant()
    .OutputInOrder();

await Api.Instance.SetProviderAsync(new FlagdProvider());

var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices(services =>
    {
        services.AddSingleton<IFeatureClient>(Api.Instance.GetClient());
        services.AddSingleton<Consumer>();
    })
    .Build();

var consumer = host.Services.GetRequiredService<Consumer>();
consumer.StartListening();

host.Run();
